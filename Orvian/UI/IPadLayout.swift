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
        guard isPad, width.isFinite, width > 0 else { return preferred }
        let minimum = max(largeText ? 220 : 140, 480 / CGFloat(preferred))
        let available = max(0, width - horizontalInset(base: margin) * 2)
        return Int(min(12, max(1, floor((available + spacing) / (minimum + spacing)))))
    }
}
