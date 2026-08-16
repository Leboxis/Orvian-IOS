import SwiftUI

/// Typage visuel d'un élément : détermine icône et teinte discrète.
enum FileKind: String, CaseIterable {
    case folder
    case image
    case video
    case audio
    case pdf
    case text
    case spreadsheet
    case presentation
    case archive
    case code
    case other

    /// Priorité : `extension_type` de l'API, puis mime, puis extension du nom.
    init(extensionType: String?, mimeType: String?, fileName: String, isDirectory: Bool) {
        if isDirectory {
            self = .folder
            return
        }
        if let mapped = FileKind.fromExtensionType(extensionType) {
            self = mapped
            return
        }
        if let mimeType {
            self = FileKind.fromMimeType(mimeType)
            return
        }
        self = FileKind.fromFileName(fileName)
    }

    /// Traduit l'`extension_type` de l'API ; nil si inconnu ou non exploitable.
    private static func fromExtensionType(_ raw: String?) -> FileKind? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "dir": return .folder
        case "file", "unknown", "font", "diagram", "form", "email", "model":
            return nil
        case "text": return .text
        default:
            return FileKind(rawValue: raw.lowercased())
        }
    }

    private static func fromMimeType(_ mime: String) -> FileKind {
        let lower = mime.lowercased()
        if lower.hasPrefix("image/") { return .image }
        if lower.hasPrefix("video/") { return .video }
        if lower.hasPrefix("audio/") { return .audio }
        if lower == "application/pdf" { return .pdf }
        if lower.contains("spreadsheet") || lower.contains("excel") { return .spreadsheet }
        if lower.contains("presentation") || lower.contains("powerpoint") || lower.hasPrefix("text/calendar") {
            return .presentation
        }
        if lower.contains("zip") || lower.contains("tar") || lower.contains("rar") || lower.contains("7z") || lower.contains("gzip") {
            return .archive
        }
        if lower.hasPrefix("text/") { return .text }
        return .other
    }

    private static func fromFileName(_ name: String) -> FileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tif", "tiff", "avif", "bmp":
            return .image
        case "mp4", "mov", "mkv", "avi", "m4v", "webm", "wmv", "mpg", "mpeg":
            return .video
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "aiff":
            return .audio
        case "pdf":
            return .pdf
        case "txt", "rtf", "md", "pages", "doc", "docx", "odt":
            return .text
        case "xls", "xlsx", "numbers", "csv", "ods":
            return .spreadsheet
        case "ppt", "pptx", "key", "odp":
            return .presentation
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "iso", "dmg":
            return .archive
        case "swift", "js", "ts", "py", "rb", "go", "rs", "c", "h", "cpp", "java", "json", "xml", "yml", "yaml", "html", "css", "sh":
            return .code
        default:
            return .other
        }
    }

    /// L'API peut-elle produire une miniature pour ce type ?
    var supportsThumbnail: Bool {
        switch self {
        case .image, .video, .pdf:
            return true
        default:
            return false
        }
    }

    var symbolName: String {
        switch self {
        case .folder: return "folder.fill"
        case .image: return "photo"
        case .video: return "play.rectangle.fill"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext.fill"
        case .text: return "doc.text.fill"
        case .spreadsheet: return "tablecells.fill"
        case .presentation: return "chart.bar.doc.horizontal.fill"
        case .archive: return "doc.zipper"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .other: return "doc.fill"
        }
    }

    /// Teinte par type — volontairement désaturées et douces.
    var tint: Color {
        switch self {
        case .folder: return Color(red: 0.26, green: 0.52, blue: 0.96)   // bleu
        case .image: return Color(red: 0.94, green: 0.35, blue: 0.62)    // rose
        case .video: return Color(red: 0.98, green: 0.45, blue: 0.21)    // orange
        case .audio: return Color(red: 0.56, green: 0.38, blue: 0.94)    // violet
        case .pdf: return Color(red: 0.94, green: 0.30, blue: 0.30)      // rouge doux
        case .text: return Color(red: 0.35, green: 0.45, blue: 0.60)     // ardoise
        case .spreadsheet: return Color(red: 0.13, green: 0.65, blue: 0.47) // vert
        case .presentation: return Color(red: 0.95, green: 0.60, blue: 0.16) // ambre
        case .archive: return Color(red: 0.63, green: 0.48, blue: 0.23)  // brun doux
        case .code: return Color(red: 0.16, green: 0.62, blue: 0.65)     // sarcelle
        case .other: return Color(red: 0.45, green: 0.48, blue: 0.53)    // gris
        }
    }
}
