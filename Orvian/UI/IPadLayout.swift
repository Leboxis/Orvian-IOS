import Foundation

/// Mesures de présentation uniquement : aucune préférence persistante n'est réécrite.
struct IPadLayout {
    var isPad = false
    var width: CGFloat = 0
    var largeText = false

    var usesTwoColumns: Bool { isPad && width >= 900 && !largeText }
    var recentPreviewLimit: Int { usesTwoColumns ? 6 : 3 }

    func horizontalInset(base: CGFloat) -> CGFloat {
        isPad && width >= 700 ? base * 2 : base
    }

    func fileColumns(preferred: Int, margin: CGFloat, spacing: CGFloat) -> Int {
        let preferred = min(max(preferred, 2), 7)
        guard width.isFinite, width > 0 else { return largeText ? 1 : min(preferred, 3) }
        // Each density has its own thumbnail size; stored phone preferences stay intact.
        let minimum = largeText ? CGFloat(220) : (isPad ? Self.thumbnailSizes[preferred - 2] : 100)
        let available = max(0, width - horizontalInset(base: margin) * 2)
        let fitting = Int(min(12, max(1, floor((available + spacing) / (minimum + spacing)))))
        return isPad ? fitting : min(preferred, fitting)
    }

    static let thumbnailSizes: [CGFloat] = [300, 240, 200, 165, 140, 110]
}
