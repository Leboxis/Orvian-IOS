import CoreML
import Vision
import ImageIO
import Foundation

/// Sérialise les inférences hors du MainActor. Le package inclut le softmax.
actor NSFWImageClassifier {
    static let shared = NSFWImageClassifier()
    static let modelVersion = "marqo-384-fp16-softmax-v1"
    private var model: VNCoreMLModel?

    func prepare() throws {
        guard model == nil else { return }
        guard let url = Bundle.main.url(forResource: "NSFWClassifier", withExtension: "mlmodelc") else {
            throw ClassificationError.modelUnavailable
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: configuration))
    }

    func classify(imageData: Data) throws -> Float {
        try Task.checkCancellation()
        try prepare()
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              CGImageSourceGetCount(source) > 0, let model else {
            throw ClassificationError.invalidImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop
        try VNImageRequestHandler(data: imageData, orientation: orientation).perform([request])
        try Task.checkCancellation()
        guard let results = request.results as? [VNClassificationObservation],
              results.count == 2,
              let nsfw = results.first(where: { $0.identifier == "NSFW" })?.confidence,
              let sfw = results.first(where: { $0.identifier == "SFW" })?.confidence,
              nsfw.isFinite, sfw.isFinite,
              (0...1).contains(nsfw), (0...1).contains(sfw),
              abs(nsfw + sfw - 1) < 0.001 else {
            throw ClassificationError.invalidScores
        }
        return nsfw
    }
}

enum ClassificationError: LocalizedError {
    case modelUnavailable, invalidImage, invalidScores, invalidPagination

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: return "Le modèle d’analyse est indisponible dans cette version de l’app."
        case .invalidImage: return "L’image ne peut pas être analysée."
        case .invalidScores: return "Le modèle n’a pas produit un résultat valide."
        case .invalidPagination: return "Le chargement du dossier est incomplet. Relancez le scan."
        }
    }
}
