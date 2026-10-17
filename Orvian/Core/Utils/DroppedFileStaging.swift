import Foundation

enum DroppedFileStaging {
    /// Copy while the provider's temporary representation is still valid.
    static func copy(_ source: URL, into root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("DroppedFiles", isDirectory: true)) throws -> URL {
        guard source.isFileURL else { throw ImportError.regularFileRequired }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ImportError.regularFileRequired
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func remove(_ urls: [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DroppedFiles", isDirectory: true).standardizedFileURL.path + "/"
        for url in urls where url.standardizedFileURL.path.hasPrefix(root) {
            try? FileManager.default.removeItem(at: url)
            let parent = url.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: parent)
            }
        }
    }

    enum ImportError: LocalizedError {
        case regularFileRequired
        var errorDescription: String? { "Déposez des fichiers locaux, pas des dossiers ni des liens." }
    }
}
