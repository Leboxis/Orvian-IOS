import SwiftUI

extension Color {
    /// Analyse « #rrggbb » ou « #rgb » ; nil si le format est inattendu.
    init?(hex: String?) {
        guard let hex else { return nil }
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 3 || value.count == 6,
              let rgb = UInt64(value, radix: 16) else {
            return nil
        }
        if value.count == 3 {
            let r = CGFloat((rgb >> 8) & 0xF) / 15
            let g = CGFloat((rgb >> 4) & 0xF) / 15
            let b = CGFloat(rgb & 0xF) / 15
            self.init(red: r, green: g, blue: b)
        } else {
            let r = CGFloat((rgb >> 16) & 0xFF) / 255
            let g = CGFloat((rgb >> 8) & 0xFF) / 255
            let b = CGFloat(rgb & 0xFF) / 255
            self.init(red: r, green: g, blue: b)
        }
    }

    /// Convertit la couleur SwiftUI en chaîne hexadécimale « #rrggbb ».
    func toHex() -> String? {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        let r = Int(round(red * 255))
        let g = Int(round(green * 255))
        let b = Int(round(blue * 255))
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
