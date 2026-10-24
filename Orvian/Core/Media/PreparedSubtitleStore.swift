import Foundation
import CryptoKit

/// Les sous-titres coûtent du calcul : Application Support (hors sauvegarde),
/// protégés et bornés à 100 Mo/128 vidéos. Les sources audio restent temporaires.
actor PreparedSubtitleStore {
    static let shared = PreparedSubtitleStore()
    private let root: URL
    private let currentCredential: @Sendable () -> String?
    private let maximumBytes = 100 * 1024 * 1024
    private let maximumFileBytes = 32 * 1024 * 1024

    init(root: URL? = nil, currentCredential: @escaping @Sendable () -> String? = { TokenStore.credentialFingerprint() }) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PreparedSubtitles", isDirectory: true)
        self.currentCredential = currentCredential
    }

    func load(_ key: PreparedSubtitleKey) -> PreparedSubtitles? {
        guard currentCredential() == key.credential,
              let url = try? location(key),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumFileBytes,
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(PreparedSubtitles.self, from: data),
              document.key == key, document.isValid else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return document
    }

    func save(_ document: PreparedSubtitles) throws {
        try Task.checkCancellation()
        guard currentCredential() == document.key.credential else { throw CancellationError() }
        guard document.isValid else { throw PreparedSubtitleError.incomplete }
        let data = try JSONEncoder().encode(document)
        guard data.count <= maximumFileBytes else { throw PreparedSubtitleError.tooLarge }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let url = try location(document.key)
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
        trim()
    }

    func remove(_ key: PreparedSubtitleKey) {
        guard currentCredential() == key.credential, let url = try? location(key) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Supprime uniquement le compte quitté ; le nom ne contient jamais le token.
    func clear(credential: String) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.lastPathComponent.hasPrefix(credential + "-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func location(_ key: PreparedSubtitleKey) throws -> URL {
        // L'empreinte est produite par TokenStore, mais on valide aussi les clés
        // relues sur disque pour interdire tout chemin fourni par un JSON altéré.
        guard !key.credential.isEmpty,
              key.credential.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw PreparedSubtitleError.storage
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: try encoder.encode(key)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("\(key.credential)-\(digest).json")
    }

    private func trim() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let files = urls.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 > $1.2 }
        var bytes = 0
        for (index, entry) in files.enumerated() {
            bytes += entry.1
            if index >= 128 || bytes > maximumBytes { try? FileManager.default.removeItem(at: entry.0) }
        }
    }
}
