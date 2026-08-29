import Foundation
import Observation

/// Contexte de la visionneuse de médias : pager horizontal sur les images et
/// vidéos voisines, dans l'ordre et avec les filtres de la grille d'origine.
struct MediaViewerContext: Identifiable {
    let driveId: Int
    /// Filtres/tri de la grille d'origine : réappliqués à chaque page chargée
    /// pour que le pager reste exactement dans le même ordre que l'onglet.
    let filters: FileFilters
    /// Recherche en cours dans l'onglet d'origine (Accueil notamment).
    let searchText: String
    /// Vue-modèle de la grille d'origine : sert uniquement à charger les pages
    /// suivantes depuis le curseur de pagination déjà positionné (aucun doublon
    /// réseau). nil = pas de pagination (liste limitée, ex. aperçus du Profil).
    let viewModel: FileGridViewModel?
    /// Médias (images + vidéos) affichés : instantané fourni par la grille.
    let files: [DriveFile]
    /// Position initiale dans `files`.
    let startIndex: Int

    var id: String { "\(driveId)-\(files.map(\.id).hashValue)-\(startIndex)" }
}

/// Ouvre les visionneuses plein écran depuis n'importe quelle grille.
@MainActor
@Observable
final class ViewerRouter {
    var mediaContext: MediaViewerContext?
    var textFile: DriveFile?

    let driveId: Int

    init(driveId: Int) {
        self.driveId = driveId
    }

    func open(
        _ file: DriveFile,
        siblings: [DriveFile],
        filters: FileFilters = .init(),
        searchText: String = "",
        viewModel: FileGridViewModel? = nil
    ) {
        MediaUsageStore.recordView(driveId: driveId, file: file)
        if file.isImage || file.isVideo {
            // Les « voisins » fournis par la grille respectent déjà le tri et
            // les filtres du moment ; on ne garde que les médias pour le pager.
            let media = siblings.filter { $0.isImage || $0.isVideo }
            let index = media.firstIndex(where: { $0.id == file.id }) ?? 0
            mediaContext = MediaViewerContext(
                driveId: driveId,
                filters: filters,
                searchText: searchText,
                viewModel: viewModel,
                files: media,
                startIndex: index
            )
        } else if file.isPlainText {
            textFile = file
        } else if !file.isDirectory {
            // Repli : les .txt sans extension visible n'ont aucune métadonnée
            // exploitable (l'API ne renvoie ni extension ni MIME fiable). La
            // visionneuse de texte télécharge le contenu, détecte le binaire
            // et affiche une erreur claire si le fichier n'est pas du texte.
            textFile = file
        }
    }
}