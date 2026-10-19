import XCTest
@testable import Orvian

/// Couvre les mémoïsations ajoutées pour la fluidité : le type fonctionnel des
/// fichiers (lu plusieurs fois par carte et deux fois par comparaison de tri)
/// et les réglages de tri/filtres relus à chaque reconstruction de vue.
final class PerformanceMemoizationTests: XCTestCase {
    /// L'initialiseur membre de `DriveFile` est synthétisé : ses paramètres
    /// n'ont pas de valeur par défaut, d'où ce raccourci lisible dans les tests.
    private func makeFile(
        id: Int,
        name: String = "fichier",
        type: String = "file",
        mimeType: String? = nil,
        extensionType: String? = nil
    ) -> DriveFile {
        DriveFile(
            id: id,
            name: name,
            type: type,
            size: nil,
            mimeType: mimeType,
            extensionType: extensionType,
            fileExtension: nil,
            isFavorite: nil,
            parentId: nil,
            path: nil,
            color: nil,
            categories: nil,
            addedAt: nil,
            lastModifiedAt: nil,
            updatedAt: nil
        )
    }

    func testFileKindIsMemoizedAndInvalidatedByItsInputs() {
        let photo = makeFile(id: 4_242, name: "photo.jpg",
                             mimeType: "image/jpeg", extensionType: "image")
        XCTAssertEqual(photo.fileKind, FileKind.image)

        // Même identifiant, contenu différent : le cache doit suivre.
        let clip = makeFile(id: 4_242, name: "clip.mov",
                            mimeType: "video/quicktime", extensionType: "video")
        XCTAssertEqual(clip.fileKind, FileKind.video,
                       "A newer version of the same file must not reuse the old kind")

        // Un GIF reste une image même si l'API annonce autre chose.
        let animation = makeFile(id: 4_243, name: "animation",
                                 mimeType: "image/gif", extensionType: "unknown")
        XCTAssertTrue(animation.isGIF)
        XCTAssertEqual(animation.fileKind, FileKind.image)

        // Les dossiers ne passent jamais par le type de fichier.
        let folder = makeFile(id: 4_244, name: "Dossier", type: "dir")
        XCTAssertEqual(folder.fileKind, FileKind.folder)
        XCTAssertFalse(folder.isGIF)
    }

    func testFileKindMatchesTheUncachedRule() {
        for extensionType in [nil, "image", "video", "unknown", "pdf"] as [String?] {
            for mime in [nil, "image/gif", "video/mp4", "text/plain"] as [String?] {
                let candidate = makeFile(id: 7, name: "fichier.gif",
                                         mimeType: mime, extensionType: extensionType)
                let expected = FileKind.compute(
                    extensionType: extensionType,
                    mimeType: mime,
                    fileName: candidate.name,
                    fileExtension: candidate.fileExtension,
                    isDirectory: candidate.isDirectory
                )
                XCTAssertEqual(candidate.fileKind, expected)
            }
        }
    }

    @MainActor
    func testFiltersStoreMemoizesTheDecodedValue() {
        let suite = "orvian.filters.memoization"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
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
        defaults.removePersistentDomain(forName: suite)
    }
}
