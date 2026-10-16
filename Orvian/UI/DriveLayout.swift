import Foundation

/// Largeur réelle du contenu : masquer la barre ne change ni les données ni les préférences.
struct DriveLayout {
    var isPad = false
    var width: CGFloat = 0

    var usesTwoColumns: Bool { isPad && width >= 800 }

    func fileColumns(preferred: Int) -> Int {
        let preferred = min(max(preferred, 2), 7)
        guard isPad else { return preferred }
        return columns(minimumWidth: max(100, 480 / CGFloat(preferred)))
    }

    func tagColumns(preferred: Int) -> Int {
        let preferred = max(2, preferred)
        guard isPad else { return preferred }
        return columns(minimumWidth: max(160, 480 / CGFloat(preferred)))
    }

    private func columns(minimumWidth: CGFloat) -> Int {
        max(1, Int((max(0, width - 28) + 10) / (minimumWidth + 10)))
    }
}
