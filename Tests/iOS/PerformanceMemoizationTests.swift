import XCTest
@testable import Orvian

/// Couvre les mémoïsations ajoutées pour la fluidité : le type fonctionnel des
/// fichiers (lu plusieurs fois par carte et deux fois par comparaison de tri)
/// et les réglages de tri/filtres relus à chaque reconstruction de vue.
final class PerformanceMemoizationTests: XCTestCase {
    func testFileKindIsMemoizedAndInvalidatedByItsInputs() {
        let file = DriveFile(id: 4_242, name: "photo.jpg", type: "file",
                             mimeType: "image/jpeg", extensionType: "image")
        XCTAssertEqual(file.fileKind, .image)

        // Même identifiant, contenu différent : le cache doit suivre.
        let renamed = DriveFile(id: 4_242, name: "clip.mov", type: "file",
                                mimeType: "video/quicktime", extensionType: "video")
        XCTAssertEqual(renamed.fileKind, .video, "A newer version of the same file must not reuse the old kind")

        // Un GIF reste une image même si l'API annonce autre chose.
        let gif = DriveFile(id: 4_243, name: "animation", type: "file",
                            mimeType: "image/gif", extensionType: "unknown")
        XCTAssertTrue(gif.isGIF)
        XCTAssertEqual(gif.fileKind, .image)

        // Les dossiers ne passent jamais par le type de fichier.
        let folder = DriveFile(id: 4_244, name: "Dossier", type: "dir")
        XCTAssertEqual(folder.fileKind, .folder)
        XCTAssertFalse(folder.isGIF)
    }

    func testFileKindMatchesTheUncachedRule() {
        for extensionType in [nil, "image", "video", "unknown", "pdf"] as [String?] {
            for mime in [nil, "image/gif", "video/mp4", "text/plain"] as [String?] {
                let file = DriveFile(id: 7, name: "fichier.gif", type: "file",
                                     mimeType: mime, extensionType: extensionType)
                let expected = FileKind.compute(
                    extensionType: extensionType,
                    mimeType: mime,
                    fileName: file.name,
                    fileExtension: file.fileExtension,
                    isDirectory: file.isDirectory
                )
                XCTAssertEqual(file.fileKind, expected)
            }
        }
    }

    @MainActor
    func testFiltersStoreMemoizesTheDecodedValue() {
        let defaults = UserDefaults(suiteName: "orvian.filters.memoization")!
        defaults.removePersistentDomain(forName: "orvian.filters.memoization")
        FileFiltersStore.clearCache()

        var filters = FileFilters()
        filters.sort = .size
        filters.media = .videos
        FileFiltersStore.save(filters, scope: .home, defaults: defaults)
        XCTAssertEqual(FileFiltersStore.load(scope: .home, defaults: defaults), filters)

        // Une écriture directe dans UserDefaults ne doit pas être vue tant que
        // la valeur mémorisée est celle que l'app vient d'écrire.
        var external = FileFilters()
        external.sort = .type
        if let data = try? JSONEncoder().encode(external) {
            defaults.set(data, forKey: "homeFileFilters")
        }
        XCTAssertEqual(FileFiltersStore.load(scope: .home, defaults: defaults), filters)

        // Après une sauvegarde par l'app, la nouvelle valeur fait foi.
        FileFiltersStore.save(external, scope: .home, defaults: defaults)
        XCTAssertEqual(FileFiltersStore.load(scope: .home, defaults: defaults), external)

        // Une portée sans valeur mémorisée retombe sur les réglages par défaut.
        XCTAssertEqual(FileFiltersStore.load(scope: .tag, defaults: defaults), FileFilters())

        FileFiltersStore.clearCache()
        defaults.removePersistentDomain(forName: "orvian.filters.memoization")
    }
}
