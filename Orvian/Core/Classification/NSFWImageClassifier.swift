import CoreML
import Vision
import ImageIO
import Foundation
import UIKit

/// Runs both local models sequentially off the main actor.
actor NSFWImageClassifier {
    static let shared = NSFWImageClassifier()
    static let modelVersion = "nudenet320n-joytag-fp16-v1"
    private var nudeModel: VNCoreMLModel?
    private var joyModel: VNCoreMLModel?

    func prepare() throws {
        guard nudeModel == nil || joyModel == nil else { return }
        let nude = try load(name: "NudeNet320n", size: 320, output: "detections", shape: [1, 22, 2100])
        let joy = try load(name: "JoyTag", size: 448, output: "semenScore", shape: [1, 1])
        nudeModel = nude
        joyModel = joy
    }

    private func load(name: String, size: Int, output: String, shape: [Int]) throws -> VNCoreMLModel {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            throw ClassificationError.modelUnavailable
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let description = model.modelDescription
        let metadata = description.metadata[.creatorDefinedKey] as? [String: String]
        guard metadata?["orvian.pipelineVersion"] == Self.modelVersion,
              let input = description.inputDescriptionsByName["image"]?.imageConstraint,
              input.pixelsWide == size, input.pixelsHigh == size,
              let tensor = description.outputDescriptionsByName[output]?.multiArrayConstraint,
              tensor.shape.map({ $0.intValue }) == shape, tensor.dataType == .float32,
              name != "JoyTag" || metadata?["orvian.tag"] == "cum" else {
            throw ClassificationError.invalidModelContract
        }
        return try VNCoreMLModel(for: model)
    }

    func classify(imageData: Data) throws -> ImageContentScores {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 448,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw ClassificationError.invalidImage
        }
        try prepare()
        guard let nudeModel, let joyModel else { throw ClassificationError.modelUnavailable }
        let detections = try infer(model: nudeModel, image: Self.paddedImage(image, size: 320, centered: false), output: "detections")
        guard detections.shape.map({ $0.intValue }) == [1, 22, 2100], detections.dataType == .float32 else {
            throw ClassificationError.invalidModelContract
        }
        let channelStride = detections.strides[1].intValue
        let candidateStride = detections.strides[2].intValue
        guard channelStride > 0, candidateStride > 0,
              21 * channelStride + 2099 * candidateStride < detections.count else {
            throw ClassificationError.invalidModelContract
        }
        let values = detections.dataPointer.assumingMemoryBound(to: Float.self)
        let scale = Float(320) / Float(max(image.width, image.height))
        let detected = try NudeNetPostprocessor.scores(candidateCount: 2100,
            contentWidth: min(320, Float(image.width) * scale), contentHeight: min(320, Float(image.height) * scale)) {
                values[$0 * channelStride + $1 * candidateStride]
            }
        try Task.checkCancellation()
        let semen = try infer(model: joyModel, image: Self.paddedImage(image, size: 448, centered: true), output: "semenScore")
        guard semen.shape.map({ $0.intValue }) == [1, 1], semen.dataType == .float32 else {
            throw ClassificationError.invalidModelContract
        }
        let scores = ImageContentScores(nudity: detected.nudity, semen: semen[0].floatValue, feet: detected.feet)
        guard scores.isValid else { throw ClassificationError.invalidScores }
        try Task.checkCancellation()
        return scores
    }

    private func infer(model: VNCoreMLModel, image: CGImage, output: String) throws -> MLMultiArray {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let results = request.results as? [VNCoreMLFeatureValueObservation],
              let tensor = results.first(where: { $0.featureName == output })?.featureValue.multiArrayValue else {
            throw ClassificationError.invalidModelContract
        }
        return tensor
    }

    /// Full-frame padding preserves feet and peripheral content; EXIF is applied at decode.
    nonisolated static func contentRect(width: Int, height: Int, size: Int, centered: Bool) -> CGRect {
        let edge = max(width, height)
        let scale = CGFloat(size) / CGFloat(edge)
        // JoyTag pads in source space using integer offsets, then resizes.
        return CGRect(x: centered ? CGFloat((edge - width) / 2) * scale : 0,
                      y: centered ? CGFloat((edge - height) / 2) * scale : 0,
                      width: CGFloat(width) * scale, height: CGFloat(height) * scale)
    }

    nonisolated static func paddedImage(_ image: CGImage, size: Int, centered: Bool) throws -> CGImage {
        let rectangle = contentRect(width: image.width, height: image.height, size: size, centered: centered)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let result = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            (centered ? UIColor.white : UIColor.black).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.cgContext.interpolationQuality = centered ? .high : .low
            UIImage(cgImage: image).draw(in: rectangle)
        }
        guard let cgImage = result.cgImage else { throw ClassificationError.invalidImage }
        return cgImage
    }
}
