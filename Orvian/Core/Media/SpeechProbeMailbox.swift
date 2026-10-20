#if DEBUG || ORVIAN_SPEECH_PROBE
import Foundation
import Synchronization

/// Copie bornée entre le callback audio et son unique consommateur.
/// Le callback essaie le verrou une fois : un engorgement arrête le test, jamais le son.
final class SpeechProbeMailbox<Metadata>: @unchecked Sendable {
    enum Failure: Int, Error { case contention = 1, overflow, oversized, sourceAudio, format }

    private final class Slot {
        let bytes: UnsafeMutableRawPointer
        var metadata: Metadata?
        var count = 0
        init(capacity: Int) { bytes = .allocate(byteCount: capacity, alignment: 16) }
        deinit { bytes.deallocate() }
    }

    private let lock = NSLock()
    private let closed = Atomic<Bool>(false)
    private let failureCode = Atomic<Int>(0)
    private let slots: [Slot]
    let byteCapacity: Int
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0

    init(slotCount: Int = 16, byteCapacity: Int = 262_144) {
        precondition(slotCount > 0 && byteCapacity > 0)
        self.byteCapacity = byteCapacity
        slots = (0..<slotCount).map { _ in Slot(capacity: byteCapacity) }
    }

    var isClosed: Bool { closed.load(ordering: .acquiring) }
    var failure: Failure? { Failure(rawValue: failureCode.load(ordering: .acquiring)) }
    func close() { closed.store(true, ordering: .releasing) }

    func fail(_ failure: Failure) {
        _ = failureCode.compareExchange(expected: 0, desired: failure.rawValue, ordering: .acquiringAndReleasing)
    }

    /// Metadata doit être un type valeur sans pointeur emprunté au callback.
    @discardableResult
    func push(_ metadata: Metadata, first: UnsafeRawBufferPointer, second: UnsafeRawBufferPointer) -> Bool {
        guard !isClosed, failure == nil else { return false }
        guard first.count <= byteCapacity, second.count <= byteCapacity - first.count else {
            fail(.oversized)
            return false
        }
        guard lock.try() else { fail(.contention); return false }
        defer { lock.unlock() }
        guard count < slots.count else { fail(.overflow); return false }
        let slot = slots[writeIndex]
        if let base = first.baseAddress, !first.isEmpty { slot.bytes.copyMemory(from: base, byteCount: first.count) }
        if let base = second.baseAddress, !second.isEmpty {
            slot.bytes.advanced(by: first.count).copyMemory(from: base, byteCount: second.count)
        }
        slot.metadata = metadata
        slot.count = first.count + second.count
        writeIndex = (writeIndex + 1) % slots.count
        count += 1
        return true
    }

    /// Seul le worker appelle pop. Sa réserve lui appartient après le retour.
    func pop(into destination: UnsafeMutableRawBufferPointer) -> Metadata? {
        precondition(destination.count >= byteCapacity)
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return nil }
        let slot = slots[readIndex]
        if slot.count > 0, let base = destination.baseAddress {
            base.copyMemory(from: slot.bytes, byteCount: slot.count)
        }
        let metadata = slot.metadata
        slot.metadata = nil
        readIndex = (readIndex + 1) % slots.count
        count -= 1
        return metadata
    }
}

/// Timeline de diagnostic : le PCM reste exploitable ; l'horloge média est
/// signalée comme fiable ou non, jamais inventée.
struct SpeechProbeTimeline {
    /// Résultat d'un bloc reçu.
    enum Acceptance: Equatable {
        /// Enchaînement continu, horloge média utilisable.
        case continuous
        /// Trou court : audio exploitable, position média ré-ancrée, retard approximatif.
        case reanchored
        /// Retour en arrière sans redémarrage de flux : ordre audio douteux.
        case restart
    }

    private(set) var origin: Double?
    private var expectedEnd: Double?
    private(set) var outputFrames: Int64 = 0
    /// Faux dès qu'une position source manquait ou a dû être ré-ancrée.
    private(set) var hasCompleteTiming = true
    private(set) var reanchorCount = 0

    /// Retour `nil` si la durée reçue n'est pas exploitable : le caller
    /// rejette alors le bloc au lieu de le faire passer pour une continuity.
    mutating func accept(start: Double, duration: Double) -> Acceptance? {
        guard duration.isFinite, duration > 0 else { return nil }
        guard start.isFinite else {
            // Le PCM reste exploitable. Ne pas inventer de position média.
            hasCompleteTiming = false
            return .continuous
        }
        guard let expectedEnd else {
            origin = start
            self.expectedEnd = start + duration
            return .continuous
        }
        let delta = start - expectedEnd
        if abs(delta) <= 0.02 {
            self.expectedEnd = start + duration
            return .continuous
        }
        self.expectedEnd = start + duration
        reanchorCount += 1
        hasCompleteTiming = false
        return delta < 0 ? .restart : .reanchored
    }

    mutating func advance(frames: Int64) -> Int64 {
        precondition(frames >= 0)
        let start = outputFrames
        outputFrames += frames
        return start
    }
}
#endif
