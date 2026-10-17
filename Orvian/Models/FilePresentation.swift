import Foundation

enum FilePresentation: String, Codable { case grid, list }

enum FileBrowserScope: String, CaseIterable {
    case home, favorites, tag
    var presentationKey: String { rawValue + "FilePresentation" }
}

enum BrowserPreferences {
    static func migrate(_ defaults: UserDefaults = .standard) {
        let legacy = defaults.object(forKey: "fileGridColumns") as? Int ?? 3
        if defaults.object(forKey: "phoneFileGridColumns") == nil {
            defaults.set(min(3, max(2, legacy)), forKey: "phoneFileGridColumns")
        }
        if defaults.object(forKey: "padFileGridDensity") == nil {
            defaults.set(min(7, max(2, legacy)), forKey: "padFileGridDensity")
        }
    }
}
