import AVFoundation
import Foundation
import UIKit

/// Aperçus de frames pour le scrubber : vignette correspondant à la position
/// visée pendant le glissement du curseur.
///
/// - Un seul générateur par vidéo (`AVAssetImageGenerator` sur l'asset déjà
///   ouvert par le lecteur) ; tolérance large : chaque frame demandée lit le
///   keyframe le plus proche, ce qui reste fluide sur un flux réseau.
/// - File d'attente « dernière intention » : pendant un drag rapide, une seule
///   génération tourne à la fois ; à son terme, seule la dernière position du
///   doigt est servie, jamais une pile de frames obsolètes.
/// - Cache mémoire borné indexé par tranche d'une demi-seconde : repasser sur
///   une zone déjà parcourue est instantané.
@MainActor
final class ScrubPreviewGenerator {
    static let shared = ScrubPreviewGenerator()

    private struct Context {
        let driveId: Int
        let fileId: Int
        let asset: AVAsset
    }

    private var generator: AVAssetImageGenerator?
    private var context: Context?
    private var frames = NSCache<NSString, UIImage>()
    /// Bucket (demi-secondes) le plus récemment demandé : une réponse d'un
    /// ancien emplacement n'écrase jamais l'aperçu courant.
    private var lastRequestedBucket = -1
    private var isRequesting = false
    private var pendingTime: Double?
    private var pendingCompletion: ((UIImage?) -> Void)?

    private init() {
        frames.countLimit = 48
    }

    func requestPreview(
        driveId: Int,
        fileId: Int,
        asset: AVAsset,
        at seconds: Double,
        completion: @escaping (UIImage?) -> Void
    ) {
        let context = Context(driveId: driveId, fileId: fileId, asset: asset)
        if contextKeyMatches(context) == false {
            install(generatorFor: context, key: context)
        }

        let bucket = Int(max(0, seconds) * 2)
        lastRequestedBucket = bucket
        let cacheKey = "\(driveId)-\(fileId)-\(bucket)" as NSString
        if let cached = frames.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        if isRequesting {
            pendingTime = seconds
            pendingCompletion = completion
            return
        }
        generate(context: context, bucket: bucket, seconds: seconds, completion: completion)
    }

    /// Oublie tout : appelé quand le lecteur change de vidéo ou se démonte.
    func reset() {
        generator = nil
        context = nil
        frames.removeAllObjects()
        lastRequestedBucket = -1
        pendingTime = nil
        pendingCompletion = nil
        isRequesting = false
    }

    // MARK: - Interne

    private func contextKeyMatches(_ candidate: Context) -> Bool {
        guard let current = context else { return false }
        return current.driveId == candidate.driveId && current.fileId == candidate.fileId
    }

    private func install(generatorFor context: Context, key: Context) {
        let generator = AVAssetImageGenerator(asset: context.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        self.generator = generator
        self.context = context
        frames.removeAllObjects()
        lastRequestedBucket = -1
    }

    private func generate(
        context: Context,
        bucket: Int,
        seconds: Double,
        completion: @escaping (UIImage?) -> Void
    ) {
        guard let generator else {
            completion(nil)
            return
        }
        isRequesting = true
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [weak self] _, cgImage, _, result, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRequesting = false

                let image: UIImage?
                if result == .succeeded, let cgImage {
                    image = UIImage(cgImage: cgImage)
                } else {
                    image = nil
                }
                if let image, bucket == self.lastRequestedBucket {
                    let cacheKey = "\(context.driveId)-\(context.fileId)-\(bucket)" as NSString
                    self.frames.setObject(
                        image,
                        forKey: cacheKey,
                        cost: Int(image.size.width * image.size.height * 4)
                    )
                }

                // Livre cette frame si elle correspond toujours à la position
                // courante, puis enchaîne immédiatement sur la dernière
                // demande mise en attente pendant la génération.
                if bucket == self.lastRequestedBucket {
                    completion(image)
                }
                if let queuedTime = self.pendingTime,
                   self.contextKeyMatches(context) {
                    let queuedCompletion = self.pendingCompletion ?? completion
                    self.pendingTime = nil
                    self.pendingCompletion = nil
                    self.generate(
                        context: context,
                        bucket: Int(max(0, queuedTime) * 2),
                        seconds: queuedTime,
                        completion: queuedCompletion
                    )
                }
            }
        }
    }
}
