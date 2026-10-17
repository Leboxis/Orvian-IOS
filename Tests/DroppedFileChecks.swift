import Foundation

@main
struct DroppedFileChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("document.txt")
        try Data("Bonjour".utf8).write(to: source)
        let copy = try DroppedFileStaging.copy(source, into: root)
        assert(copy != source && copy.lastPathComponent == source.lastPathComponent)
        let contents = try Data(contentsOf: copy)
        assert(contents == Data("Bonjour".utf8))
        do {
            _ = try DroppedFileStaging.copy(root, into: root)
            assertionFailure("Directories must be refused")
        } catch {}
        #if !os(Windows)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        do {
            _ = try DroppedFileStaging.copy(link, into: root)
            assertionFailure("Symbolic links must be refused")
        } catch {}
        #endif
        let staged = try DroppedFileStaging.copy(source)
        DroppedFileStaging.remove([staged, source])
        assert(!FileManager.default.fileExists(atPath: staged.path))
        assert(FileManager.default.fileExists(atPath: source.path), "Cleanup must never delete user source files")
        do {
            _ = try DroppedFileStaging.copy(URL(string: "https://example.com/document.txt")!, into: root)
            assertionFailure("Remote URLs must never become file imports")
        } catch {}
        print("Dropped file validation and staging checks passed")
    }
}
