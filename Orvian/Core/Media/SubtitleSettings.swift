import Foundation

/// Clés communes au lecteur et aux Réglages, persistées par AppStorage.
enum SubtitleSettings {
    static let modeKey = "subtitlePreferredMode"
    static let sourceKey = "subtitleSourceLanguage"
    static let fontSizeKey = "subtitleFontSize"
    static let backgroundOpacityKey = "subtitleBackgroundOpacity"
    static let displayDurationKey = "subtitleDisplayDuration"

    static let defaultFontSize = 17.0
    static let defaultBackgroundOpacity = 0.72
    static let defaultDisplayDuration = 6.0

    static func fontSize(_ value: Double) -> Double {
        value.isFinite ? min(28, max(14, value)) : defaultFontSize
    }
    static func backgroundOpacity(_ value: Double) -> Double {
        value.isFinite ? min(0.95, max(0.6, value)) : defaultBackgroundOpacity
    }
    static func displayDuration(_ value: Double) -> Double {
        value.isFinite ? min(10, max(3, value)) : defaultDisplayDuration
    }
}
