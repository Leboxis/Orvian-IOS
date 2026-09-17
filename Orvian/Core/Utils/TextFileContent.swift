import Foundation

/// Décode le texte avant de rechercher les caractères de contrôle dans les
/// UTF-16 : leurs octets nuls font partie de l'encodage, pas du contenu.
enum TextFileContent {
    enum DecodeError: LocalizedError {
        case unsupportedEncoding, binaryContent

        var errorDescription: String? {
            switch self {
            case .unsupportedEncoding: return "L’encodage de ce fichier texte n’est pas pris en charge."
            case .binaryContent: return "Ce fichier n’est pas un document texte."
            }
        }
    }

    static func decode(_ data: Data) throws -> String {
        let isUTF16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        let text: String?
        if isUTF16 {
            text = String(data: data, encoding: .utf16)
        } else {
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1)
        }
        guard let text else { throw DecodeError.unsupportedEncoding }
        let sample = isUTF16 ? Data(text.utf8.prefix(8_192)) : Data(data.prefix(8_192))
        if !sample.isEmpty {
            let controls = sample.filter { $0 < 0x09 || ($0 > 0x0D && $0 < 0x20) }.count
            guard !sample.contains(0), Double(controls) / Double(sample.count) <= 0.05 else {
                throw DecodeError.binaryContent
            }
        }
        return text
    }
}
