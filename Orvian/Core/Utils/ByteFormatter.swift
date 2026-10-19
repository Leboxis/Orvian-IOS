import Foundation

enum ByteFormatter {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = true
        return formatter
    }()

    /// 1 844 674 400 → « 1,84 Go » (adapté à la locale).
    static func string(fromBytes bytes: Int?) -> String {
        guard let bytes, bytes >= 0 else { return "—" }
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func format(_ bytes: Int?) -> String {
        string(fromBytes: bytes)
    }
}
