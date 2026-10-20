#if DEBUG
import AVFoundation
import XCTest
@testable import Orvian

@MainActor
final class SpeechProbeTests: XCTestCase {
    func testExistingAudioMixIsRejectedWithoutReplacement() throws {
        let composition = AVMutableComposition()
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid))
        let item = AVPlayerItem(asset: composition)
        let mix = AVMutableAudioMix()
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(0.5, at: .zero)
        mix.inputParameters = [parameters]
        item.audioMix = mix
        let existing = try XCTUnwrap(item.audioMix)
        do {
            let tap = try PlayerSpeechAudioTap(item: item, track: track)
            tap.detach()
            XCTFail("An existing audio mix must be rejected")
        } catch SpeechProbeError.existingMix {
            // Le refus doit précéder l'installation du tap.
        }
        XCTAssertTrue(item.audioMix === existing, "The exact existing mix must remain installed")
    }

    func testDetachRestoresTheItemWithoutResumingPlayback() throws {
        let composition = AVMutableComposition()
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid))
        let item = AVPlayerItem(asset: composition)
        let tap = try PlayerSpeechAudioTap(item: item, track: track)
        XCTAssertNotNil(item.audioMix)
        XCTAssertTrue(tap.detach())
        XCTAssertNil(item.audioMix, "Detach restores the previous mix")
        XCTAssertFalse(tap.detach(), "A stale detach must not erase a replacement mix")
    }

    // Manuel uniquement : fixture anglaise locale et modèle déjà installé via le panneau Debug.
    func testManualLocalEnglishFixtureProducesPCMAndTranscript() async throws {
        guard ProcessInfo.processInfo.environment["ORVIAN_RUN_SPEECH_PROBE"] == "1" else {
            throw XCTSkip("Opt-in only: set ORVIAN_RUN_SPEECH_PROBE=1 on a supported device")
        }
        guard let fixture = Bundle(for: SpeechProbeTests.self).url(forResource: "speech-probe-en", withExtension: "mp4") else {
            throw XCTSkip("Provide speech-probe-en.mp4 in the test bundle; no fixture is downloaded")
        }
        let player = AVPlayer(url: fixture)
        let probe = VideoSpeechProbe()
        defer {
            probe.stop()
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        probe.start(player: player, allowDownload: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        // Ne pas manquer la première phrase pendant la préparation du modèle.
        while probe.isRunning, !probe.isCapturing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        if probe.needsDownload {
            throw XCTSkip("Install the English model through the debug panel first; this test never downloads it")
        }
        guard probe.isCapturing else { XCTFail(probe.status); return }
        player.play()
        while probe.isRunning, (probe.buffers == 0 || probe.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(probe.buffers, 0, probe.status)
        XCTAssertFalse(probe.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, probe.status)
    }
}
#endif
