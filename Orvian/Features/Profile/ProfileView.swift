import SwiftUI

/// Onglet « Profil » : uploads récents, médias consultés, corbeille, à propos.
struct ProfileView: View {
    let session: SessionStore
    let router: ViewerRouter
    @Binding var path: NavigationPath
    var isSelected: Bool = false

    @State private var recentUploads: [DriveFile] = []
    @State private var frequentFavorites: [DriveFile] = []
    @State private var isLoadingRecents = true
    @State private var isLoadingFavorites = true

    private let service = KDriveService()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                headerSection
                recentUploadsSection
                frequentFavoritesSection
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
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.56, green: 0.38, blue: 0.94)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.white)
                }
                .frame(width: 76, height: 76)

                Text("Profil")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
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
            HStack {
                Text("Uploads récents")
                Spacer()
                if let drive = session.selectedDrive {
                    NavigationLink {
                        RecentFilesView(
                            driveId: drive.id,
                            title: "Uploads récents",
                            source: .recents(limit: 12),
                            router: router
                        )
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Médias les plus consultés (3 miniatures + bouton voir plus)

    private var frequentFavoritesSection: some View {
        Section {
            if let drive = session.selectedDrive {
                if isLoadingFavorites {
                    thumbnailsSkeleton
                } else if frequentFavorites.isEmpty {
                    Text("Aucun média consulté")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        ForEach(frequentFavorites.prefix(3)) { file in
                            Button {
                                router.open(file, siblings: frequentFavorites)
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
            HStack {
                Text("Médias les plus consultés")
                Spacer()
                if let drive = session.selectedDrive {
                    NavigationLink {
                        RecentFilesView(
                            driveId: drive.id,
                            title: "Médias les plus consultés",
                            source: .mostViewed(limit: 12),
                            router: router
                        )
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

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
        } header: {
            Text("À propos")
        } footer: {
            Text("Orvian est un client non officiel pour kDrive (Infomaniak).")
        }
    }

    // MARK: - Chargement

    private func loadPreviews() async {
        guard let drive = session.selectedDrive else { return }

        // Chargement immédiat des médias les plus consultés (synchrone local)
        let tracked = MediaUsageStore.mostViewedFiles(driveId: drive.id, limit: 12)
        if !tracked.isEmpty {
            frequentFavorites = tracked
            isLoadingFavorites = false
        }

        async let recentsTask = try? service.page(.recents(limit: 12), driveId: drive.id, cursor: nil)
        async let favsTask = try? service.page(.favorites(limit: 12), driveId: drive.id, cursor: nil)

        let (recentsPage, favsPage) = await (recentsTask, favsTask)
        if let recentsPage {
            recentUploads = (recentsPage.data ?? []).filter { !$0.isDirectory }
        }
        isLoadingRecents = false

        if frequentFavorites.isEmpty {
            if let favsPage {
                frequentFavorites = (favsPage.data ?? []).filter { !$0.isDirectory }
            }
        }
        isLoadingFavorites = false
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
            image = await ThumbnailProvider.shared.thumbnail(driveId: driveId, fileId: file.id, pixels: 200)
        }
    }
}
