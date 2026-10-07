import Foundation

/// NudeNet's winning-class policy and class-agnostic NMS (0.25/0.45).
/// Coordinates stay in the 320px square; padding-only boxes are discarded.
enum NudeNetPostprocessor {
    private struct Detection {
        let label: Int
        let score: Float
        let x: Float, y: Float, width: Float, height: Float

        func overlap(_ other: Detection) -> Float {
            let intersection = max(0, min(x + width, other.x + other.width) - max(x, other.x))
                * max(0, min(y + height, other.y + other.height) - max(y, other.y))
            let union = width * height + other.width * other.height - intersection
            return union > 0 ? intersection / union : 0
        }
    }

    static func scores(candidateCount: Int, contentWidth: Float, contentHeight: Float,
                       value: (Int, Int) -> Float) throws -> (nudity: Float, feet: Float) {
        guard candidateCount > 0, candidateCount <= 2100,
              contentWidth.isFinite, contentHeight.isFinite,
              contentWidth > 0, contentWidth <= 320, contentHeight > 0, contentHeight <= 320 else {
            throw ClassificationError.invalidScores
        }
        var candidates: [Detection] = []
        for index in 0..<candidateCount {
            var label = 0
            var score: Float = 0
            for category in 0..<18 {
                let probability = value(category + 4, index)
                guard probability.isFinite, (0...1).contains(probability) else {
                    throw ClassificationError.invalidScores
                }
                if probability > score { label = category; score = probability }
            }
            let centerX = value(0, index), centerY = value(1, index)
            let width = value(2, index), height = value(3, index)
            guard [centerX, centerY, width, height].allSatisfy(\.isFinite), width >= 0, height >= 0 else {
                throw ClassificationError.invalidScores
            }
            guard score > 0.25 else { continue }
            let x = min(contentWidth, max(0, centerX - width / 2))
            let y = min(contentHeight, max(0, centerY - height / 2))
            let clippedWidth = min(width, contentWidth - x)
            let clippedHeight = min(height, contentHeight - y)
            guard clippedWidth > 0, clippedHeight > 0 else { continue }
            candidates.append(Detection(label: label, score: score, x: x, y: y,
                                        width: clippedWidth, height: clippedHeight))
        }
        candidates.sort { $0.score > $1.score }
        var accepted: [Detection] = []
        for candidate in candidates {
            if !accepted.contains(where: { $0.overlap(candidate) > 0.45 }) {
                accepted.append(candidate)
            }
        }
        // Faces, belly, armpits, covered parts and male chests aren't nudity.
        let nudeClasses: Set<Int> = [2, 3, 4, 6, 14]
        return (accepted.filter { nudeClasses.contains($0.label) }.map(\.score).max() ?? 0,
                accepted.filter { $0.label == 7 }.map(\.score).max() ?? 0)
    }
}
