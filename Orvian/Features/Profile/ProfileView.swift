import SwiftUI

/// Onglet « Profil » : uploads récents, médias consultés, corbeille, à propos.
struct ProfileView: View {
    let session: SessionStore
    let router: ViewerRouter
    @Binding var path: NavigationPath
    var isSelected: Bool = false
    /// Incrémenté à chaque second appui sur l'onglet Profil (retour à la
    /// racine + rafraîchissement des sections).
    var refreshRequest: Int = 0

    @State private var recentUploads: [DriveFile] = []
    @State private var isLoadingRecents = true

    private let service = KDriveService()
    private let previewSource = FileSource.recents(limit: 12)

    /// Âge au-delà duquel l'instantané partagé est revalidé en arrière-plan.
    /// En deçà, chaque sélection de l'onglet n'émet aucune requête :
    /// `/files/last_modified` coûte ~1 s de calcul serveur par appel et ne
    /// doit pas repartir pour trois miniatures à chaque bascule d'onglet.
    private static let revalidationInterval: TimeInterval = 60

    var body: some View {
        NavigationStack(path: $path) {
            List {
                recentUploadsSection
                trashSection
                aboutSection
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 90)
            }
            .navigationTitle("Profil")
            .navigationBarTitleDisplayMode(.large)
        }
        .task {
            await loadPreviews()
        }
        .onChange(of: isSelected) { _, selected in
            if selected {
                Task {
                    await loadPreviews()
                }
            }
        }
        .onChange(of: refreshRequest) { _, _ in
            Task {
                // Retour à la racine par second appui sur l'onglet : lecture
                // réseau explicite, hors seuil de fraîcheur.
                await loadPreviews(forceNetwork: true)
            }
        }
    }

    // MARK: - Uploads récents (3 miniatures + bouton voir plus)

    private var recentUploadsSection: some View {
        Section {
            if let drive = session.selectedDrive {
                if isLoadingRecents {
                    thumbnailsSkeleton
                } else if recentUploads.isEmpty {
                    Text("Aucun upload récent")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        ForEach(recentUploads.prefix(3)) { file in
                            Button {
                                router.open(file, siblings: recentUploads)
                            } label: {
                                ProfileThumbnailCard(file: file, driveId: drive.id)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            if let drive = session.selectedDrive {
                NavigationLink {
                    RecentFilesView(
                        driveId: drive.id,
                        title: "Uploads récents",
                        source: .recents(limit: 12),
                        router: router
                    )
                } label: {
                    HStack {
                        Text("Uploads récents")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Uploads récents")
            }
        }
    }

    // MARK: - Médias les plus consultés (3 miniatures + bouton voir plus)

    private var thumbnailsSkeleton: some View {
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.quaternary.opacity(0.3))
                        .frame(height: 10)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    private var trashSection: some View {
        Section {
            if let drive = session.selectedDrive {
                NavigationLink {
                    TrashView(driveId: drive.id, router: router)
                } label: {
                    Label("Corbeille", systemImage: "trash")
                }
            }
        } header: {
            Text("Stockage")
        } footer: {
            Text("Les fichiers supprimés restent dans la corbeille jusqu'à leur effacement définitif.")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Label("Version", systemImage: "info.circle")
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .foregroundStyle(.secondary)
            }
            NavigationLink {
                PerfView()
            } label: {
                Label("Mesures réseau", systemImage: "gauge.with.dots")
            }
        } header: {
            Text("À propos")
        } footer: {
            Text("Orvian est un client non officiel pour kDrive (Infomaniak).")
        }
    }

    // MARK: - Chargement

    private func loadPreviews(forceNetwork: Bool = false) async {
        guard let drive = session.selectedDrive else { return }

        // Instantané partagé avec la grille « Uploads récents » : les
        // miniatures s'affichent sans attendre le réseau, et un onglet
        // consulté à moins de 60 s d'intervalle n'émet aucune requête —
        // `/files/last_modified` coûte ~1 s de calcul serveur par appel.
        // Au-delà, revalidation silencieuse (ETag → 304 si rien n'a changé).
        if !forceNetwork,
           let snapshot = DirectoryListStore.shared.snapshot(
            source: previewSource,
            driveId: drive.id,
            orderBy: [],
            order: "asc"
           ) {
            recentUploads = snapshot.items.filter { !$0.isDirectory }
            isLoadingRecents = false
            if Date().timeIntervalSince(snapshot.fetchedAt) < Self.revalidationInterval {
                return
            }
        }

        if let recentsPage = try? await service.page(previewSource, driveId: drive.id, cursor: nil, forceNetwork: forceNetwork) {
            let files = (recentsPage.data ?? []).filter { !$0.isDirectory }
            recentUploads = files
            // Alimente le cache partagé (bascules d'onglet suivantes, grille)
            // sans écraser un instantané de grille plus profondément paginé.
            let existingCount = DirectoryListStore.shared.snapshot(
                source: previewSource,
                driveId: drive.id,
                orderBy: [],
                order: "asc"
            )?.items.count ?? 0
            if existingCount <= files.count {
                DirectoryListStore.shared.store(
                    source: previewSource,
                    driveId: drive.id,
                    orderBy: [],
                    order: "asc",
                    items: files,
                    cursor: recentsPage.cursor,
                    hasMore: recentsPage.hasMore ?? false,
                    totalItemCount: nil
                )
            }
        }
        isLoadingRecents = false
    }
}

// MARK: - Vignette de prévisualisation dans le profil

private struct ProfileThumbnailCard: View {
    let file: DriveFile
    let driveId: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.quaternary.opacity(0.35))

                        if let thumb = ThumbnailProvider.shared.cachedMemoryThumbnail(driveId: driveId, fileId: file.id) {
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFill()
                        } else {
                            AsyncProfileThumbnail(file: file, driveId: driveId)
                        }

                        if file.isVideo {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.black.opacity(0.06), lineWidth: 0.5)
                }

            Text(file.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .contextMenu {
            if !file.isDirectory {
                Button {
                    Task {
                        await FileDownloadService.shared.downloadAndShare(driveId: driveId, file: file)
                    }
                } label: {
                    Label("Télécharger", systemImage: "arrow.down.circle")
                }
            }
        }
    }
}

private struct AsyncProfileThumbnail: View {
    let file: DriveFile
    let driveId: Int
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: file.fileKind.symbolName)
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(file.fileKind.tint)
            }
        }
        .task(id: file.id) {
            guard file.fileKind.supportsThumbnail else { return }
            // Clé canonique partagée avec les grilles : miniature servie
            // depuis le cache au lieu d'un second téléchargement.
            image = await ThumbnailProvider.shared.thumbnail(driveId: driveId, fileId: file.id)
        }
    }
}
