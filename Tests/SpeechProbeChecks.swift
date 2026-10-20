import Dispatch
import Foundation
import Synchronization

@main
struct SpeechProbeChecks {
    private struct Packet: Equatable {
        var sequence: Int
        let firstBytes: Int
        let secondBytes: Int
    }

    private static func push(_ mailbox: SpeechProbeMailbox<Packet>, _ sequence: Int,
                             first: [UInt8], second: [UInt8] = []) -> Bool {
        first.withUnsafeBytes { firstBytes in
            second.withUnsafeBytes { secondBytes in
                mailbox.push(Packet(sequence: sequence, firstBytes: first.count, secondBytes: second.count),
                             first: firstBytes, second: secondBytes)
            }
        }
    }

    @discardableResult
    private static func expectPop(_ mailbox: SpeechProbeMailbox<Packet>, _ sequence: Int,
                                  first: [UInt8], second: [UInt8] = []) -> [UInt8] {
        let expected = first + second
        var destination = [UInt8](repeating: 0xCC, count: mailbox.byteCapacity + 8)
        let packet = destination.withUnsafeMutableBytes { mailbox.pop(into: $0) }
        assert(packet == Packet(sequence: sequence, firstBytes: first.count, secondBytes: second.count))
        assert(Array(destination.prefix(expected.count)) == expected)
        assert(destination.dropFirst(expected.count).allSatisfy { $0 == 0xCC }, "Copy must not overrun the packet")
        return destination
    }

    private static func expectEmpty(_ mailbox: SpeechProbeMailbox<Packet>) {
        var destination = [UInt8](repeating: 0xCC, count: mailbox.byteCapacity)
        let packet = destination.withUnsafeMutableBytes { mailbox.pop(into: $0) }
        assert(packet == nil)
        assert(destination.allSatisfy { $0 == 0xCC }, "Empty pop must not touch worker storage")
    }

    private static func copiesOwnedBytesAndMetadata() {
        let mailbox = SpeechProbeMailbox<Packet>(slotCount: 2, byteCapacity: 16)
        assert(!mailbox.isClosed && mailbox.failure == nil)
        expectEmpty(mailbox)
        let original: [UInt8] = [0, 255, 128, 0, 42]
        var source = original
        var packet = Packet(sequence: 7, firstBytes: source.count, secondBytes: 0)
        let accepted = source.withUnsafeBytes {
            mailbox.push(packet, first: $0, second: UnsafeRawBufferPointer(start: nil, count: 0))
        }
        assert(accepted)
        for index in source.indices { source[index] = 0xEE }
        packet.sequence = 99
        assert(push(mailbox, 8, first: [8, 0, 254]))
        let owned = expectPop(mailbox, 7, first: original)
        expectPop(mailbox, 8, first: [8, 0, 254])
        assert(push(mailbox, 9, first: [9, 9, 9, 9, 9]))
        expectPop(mailbox, 9, first: [9, 9, 9, 9, 9])
        assert(Array(owned.prefix(original.count)) == original, "Slot reuse must not change popped bytes")
        expectEmpty(mailbox)
    }

    private static func planarSpansAndEmptyEndPacket() {
        let mailbox = SpeechProbeMailbox<Packet>(slotCount: 2, byteCapacity: 8)
        let left: [UInt8] = [0, 1, 0x80, 0xFF]
        let right: [UInt8] = [0xFE, 0x81, 2, 0]
        assert(push(mailbox, 0, first: left, second: right), "Exact combined capacity is valid")
        expectPop(mailbox, 0, first: left, second: right)
        assert(push(mailbox, 1, first: [], second: [3, 4]))
        expectPop(mailbox, 1, first: [], second: [3, 4])
        assert(push(mailbox, 2, first: []), "An empty EOS packet still carries metadata")
        expectPop(mailbox, 2, first: [])
        assert(mailbox.failure == nil)
    }

    private static func fifoWrapsWithoutLosingUnreadSlots() {
        let mailbox = SpeechProbeMailbox<Packet>(slotCount: 3, byteCapacity: 1)
        for base in stride(from: 0, to: 160, by: 5) {
            for sequence in base..<(base + 3) {
                assert(push(mailbox, sequence, first: [UInt8(sequence)]))
            }
            for sequence in base..<(base + 2) {
                expectPop(mailbox, sequence, first: [UInt8(sequence)])
            }
            for sequence in (base + 3)..<(base + 5) {
                assert(push(mailbox, sequence, first: [UInt8(sequence)]))
            }
            for sequence in (base + 2)..<(base + 5) {
                expectPop(mailbox, sequence, first: [UInt8(sequence)])
            }
            expectEmpty(mailbox)
        }
        assert(mailbox.failure == nil)
    }

    private static func terminalFailuresAndClose() {
        let full = SpeechProbeMailbox<Packet>(slotCount: 1, byteCapacity: 2)
        assert(push(full, 0, first: [1, 2]))
        assert(!push(full, 1, first: [3]))
        assert(full.failure == .overflow)
        expectPop(full, 0, first: [1, 2])
        assert(!push(full, 2, first: [4]), "Overflow remains terminal after draining")
        full.fail(.format)
        full.close()
        assert(full.failure == .overflow && full.isClosed)
        expectEmpty(full)

        for spans in [([UInt8](repeating: 1, count: 5), []),
                      ([UInt8](repeating: 1, count: 3), [UInt8](repeating: 2, count: 2)),
                      ([], [UInt8](repeating: 2, count: 5))] {
            let oversized = SpeechProbeMailbox<Packet>(slotCount: 2, byteCapacity: 4)
            assert(push(oversized, 0, first: [7]))
            assert(!push(oversized, 1, first: spans.0, second: spans.1))
            assert(oversized.failure == .oversized)
            expectPop(oversized, 0, first: [7])
            assert(!push(oversized, 2, first: [8]))
            expectEmpty(oversized)
        }

        let closed = SpeechProbeMailbox<Packet>(slotCount: 1, byteCapacity: 2)
        assert(push(closed, 0, first: [5]))
        closed.close()
        closed.close()
        assert(closed.isClosed)
        assert(!push(closed, 1, first: [6]))
        assert(!push(closed, 2, first: [1, 2, 3]), "Closed rejection precedes size validation")
        assert(closed.failure == nil)
        expectPop(closed, 0, first: [5])
        expectEmpty(closed)

        let failures: [SpeechProbeMailbox<Packet>.Failure] = [.contention, .overflow, .oversized, .sourceAudio, .format]
        for first in failures {
            let failed = SpeechProbeMailbox<Packet>(slotCount: 1, byteCapacity: 1)
            failed.fail(first)
            for later in failures { failed.fail(later) }
            assert(failed.failure == first, "The first failure must win")
            assert(!push(failed, 0, first: [0]))
            assert(!failed.isClosed, "Failure and closure are independent signals")
            expectEmpty(failed)
        }
    }

    private static func concurrentWorkerCopiesOrTerminatesOnContention() {
        let count = 512
        let mailbox = SpeechProbeMailbox<Packet>(slotCount: count, byteCapacity: 256)
        let available = DispatchSemaphore(value: 0)
        let worker = DispatchGroup()
        let consumed = Atomic<Int>(0)
        // Seed one packet before scheduling so every run checks actual worker copying.
        assert(push(mailbox, 0, first: [UInt8](repeating: 0, count: 256)))
        available.signal()
        worker.enter()
        DispatchQueue.global().async {
            defer { worker.leave() }
            var expected = 0
            var scratch = [UInt8](repeating: 0xCC, count: mailbox.byteCapacity)
            while true {
                assert(available.wait(timeout: .now() + 10) == .success, "Producer must finish or signal a packet")
                let packet = scratch.withUnsafeMutableBytes { mailbox.pop(into: $0) }
                guard let packet else {
                    assert(mailbox.isClosed)
                    break
                }
                assert(packet == Packet(sequence: expected, firstBytes: 256, secondBytes: 0))
                assert(scratch.allSatisfy { $0 == UInt8(truncatingIfNeeded: expected) })
                expected += 1
            }
            consumed.store(expected, ordering: .releasing)
        }
        var accepted = 1
        for sequence in 1..<count {
            let bytes = [UInt8](repeating: UInt8(truncatingIfNeeded: sequence), count: 256)
            guard push(mailbox, sequence, first: bytes) else { break }
            accepted += 1
            available.signal()
        }
        mailbox.close()
        available.signal()
        assert(worker.wait(timeout: .now() + 10) == .success, "Worker must not deadlock")
        assert(consumed.load(ordering: .acquiring) == accepted, "Every accepted packet must be copied once in FIFO order")
        // try-lock contention is intentionally terminal; do not require a lucky schedule.
        assert(mailbox.failure == nil || mailbox.failure == .contention)
        assert(!push(mailbox, count, first: [0]))
        expectEmpty(mailbox)
    }

    private static func timelineRejectsInvalidAndDiscontinuousInput() {
        var timeline = SpeechProbeTimeline()
        assert(timeline.origin == nil && timeline.outputFrames == 0)
        for duration in [Double.nan, .infinity, -.infinity, 0, -1] {
            var invalid = SpeechProbeTimeline()
            assert(invalid.accept(start: 10, duration: duration) == nil,
                   "Only the duration must be strictly positive")
        }
        for start in [Double.nan, .infinity, -.infinity] {
            var untimed = SpeechProbeTimeline()
            assert(untimed.accept(start: start, duration: 1) == .continuous)
            assert(untimed.origin == nil && !untimed.hasCompleteTiming)
        }
        assert(timeline.accept(start: 10, duration: 0.25) == .continuous)
        assert(timeline.origin == 10)
        assert(timeline.accept(start: 10.5, duration: 0.25) == .reanchored, "A gap stays usable audio")
        assert(!timeline.hasCompleteTiming && timeline.reanchorCount == 1)
        assert(timeline.accept(start: 10, duration: 0.25) == .restart, "A backward jump is flagged")
        assert(timeline.reanchorCount == 2)
        assert(timeline.accept(start: 10.25, duration: 0.25) == .continuous)
        assert(timeline.accept(start: 10.515, duration: 0.25) == .continuous, "Small positive jitter is tolerated")
        assert(timeline.accept(start: 10.75, duration: 0.25) == .continuous, "Small negative jitter is tolerated")
        assert(timeline.accept(start: 11.021, duration: 0.25) == .reanchored, "Jitter outside 20 ms re-anchors")
        assert(timeline.accept(start: 11.271, duration: 0.25) == .continuous, "The re-anchored baseline continues")
        assert(timeline.origin == 10)
        assert(timeline.outputFrames == 0, "Source time must not advance converted output frames")
        assert(timeline.advance(frames: 0) == 0)
        assert(timeline.advance(frames: 160) == 0)
        assert(timeline.advance(frames: 320) == 160)
        assert(timeline.advance(frames: 0) == 480)
        assert(timeline.outputFrames == 480)
        assert(timeline.origin == 10)
    }

    private static func firstPCMWithoutTimestampMustNotLookLikeASeek() {
        var timeline = SpeechProbeTimeline()
        // Un paquet PCM peut être exploitable avant que sa position média le soit.
        let receivedFrames: Int64 = 1024
        let duration = Double(receivedFrames) / 48_000
        assert(timeline.accept(start: .nan, duration: duration) == .continuous,
               "Regression: the first real PCM packet was rejected as a discontinuity before PCM counting")
        assert(timeline.origin == nil && !timeline.hasCompleteTiming, "Never fabricate a media clock")
        assert(timeline.advance(frames: receivedFrames) == 0)
        assert(timeline.outputFrames == receivedFrames)
        assert(timeline.accept(start: 12, duration: duration) == .continuous,
               "The first usable timestamp establishes the baseline instead of failing the test")
        assert(!timeline.hasCompleteTiming, "The earlier untimed packet keeps the lag approximate")
        assert(timeline.origin == 12)
    }

    static func main() {
        firstPCMWithoutTimestampMustNotLookLikeASeek()
        copiesOwnedBytesAndMetadata()
        planarSpansAndEmptyEndPacket()
        fifoWrapsWithoutLosingUnreadSlots()
        terminalFailuresAndClose()
        concurrentWorkerCopiesOrTerminatesOnContention()
        timelineRejectsInvalidAndDiscontinuousInput()
        print("Speech probe mailbox and timeline checks passed")
    }
}
