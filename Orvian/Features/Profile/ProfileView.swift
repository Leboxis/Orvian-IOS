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
    @Environment(\.iPadLayout) private var iPadLayout
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var recentUploads: [DriveFile] = []
    @State private var isLoadingRecents = true
    @State private var recentError: String?
    @State private var previewRequestID = UUID()
    @State private var previewDriveId: Int?
    @State private var previewCredential: String?

    private let recentUploadsLoader = RecentUploadsLoader.shared

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if iPadLayout.isPad {
                    padOverview
                } else {
                    List {
                        recentUploadsSection
                        trashSection
                        aboutSection
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: DS.contentBottomInset)
            }
            .navigationTitle("Profil")
            // Le mode inline masque la barre sur un contenu qui défile : le
            // grand titre reste, et le bloc ci-dessous prend l'axe du titre.
            .navigationBarTitleDisplayMode(.large)
        }
        .task(id: session.selectedDrive?.id) {
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
        .onReceive(FileGridMutationCenter.shared.mutations) { mutation in
            guard case let .uploaded(driveId, files) = mutation,
                  driveId == session.selectedDrive?.id else { return }
            mergeUploaded(files)
        }
    }

    // MARK: - Uploads récents (3 miniatures + bouton voir plus)

    private var padOverview: some View {
        let layout = iPadLayout.usesTwoColumns
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
        return ScrollView {
            layout {
                padRecents
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                padInformation
                    .frame(width: iPadLayout.usesTwoColumns ? 280 : nil)
            }
            .padding(.horizontal, iPadLayout.horizontalInset(base: DS.gridMargin))
            .padding(.top, 16)
            .padding(.bottom, DS.contentBottomInset)
            // Même décision que la grille de tags : au-delà de 900 pt, les
            // trois aperçus s'étirent et les vignettes deviennent énormes.
            // Le bloc reste sur l'axe du grand titre (pas centré).
            .frame(maxWidth: DS.maxContentWidth)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var padRecents: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Imports récents").font(.headline)
                Spacer()
                if let drive = session.selectedDrive,
                   isLoadingRecents || !recentUploads.isEmpty {
                    NavigationLink("Voir plus") {
                        RecentFilesView(driveId: drive.id, title: "Imports récents",
                                        source: RecentUploadsLoader.source, router: router)
                    }
                }
            }
            if let recentError {
                recentFailure(recentError)
            }
            if !isLoadingRecents && recentUploads.isEmpty && recentError == nil {
                Text("Aucun import récent")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if isLoadingRecents || !recentUploads.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.gridSpacing),
                                          count: iPadLayout.largeText ? 1 : 3), spacing: 16) {
                    if isLoadingRecents {
                        ForEach(0..<iPadLayout.recentPreviewLimit, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: DS.cardRadius)
                                .fill(.quaternary.opacity(0.4))
                                .aspectRatio(1, contentMode: .fit)
                                .accessibilityHidden(true)
                        }
                    } else if let drive = session.selectedDrive {
                        ForEach(recentUploads.prefix(iPadLayout.recentPreviewLimit)) { file in
                            Button {
                                router.open(file, siblings: recentUploads)
                            } label: {
                                ProfileThumbnailCard(file: file, driveId: drive.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: DS.panelRadius))
    }

    private var padInformation: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Stockage et informations").font(.headline)
            if let drive = session.selectedDrive {
                NavigationLink(destination: TrashView(driveId: drive.id, router: router)) {
                    LinkRowLabel(title: "Corbeille", systemImage: "trash")
                }
            }
            Divider()
            HStack {
                Label("Version", systemImage: "info.circle")
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .foregroundStyle(.secondary)
            }
            NavigationLink(destination: PerfView()) {
                LinkRowLabel(title: "Mesures réseau", systemImage: "gauge.with.dots")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: DS.panelRadius))
    }

    private var recentUploadsSection: some View {
        Section {
            if let drive = session.selectedDrive {
                if let recentError { recentFailure(recentError) }
                if isLoadingRecents {
                    thumbnailsSkeleton
                } else if recentUploads.isEmpty && recentError == nil {
                    Text("Aucun import récent")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                    layout {
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
                        title: "Imports récents",
                        source: RecentUploadsLoader.source,
                        router: router
                    )
                } label: {
                    HStack {
                        Text("Imports récents")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Imports récents")
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
            Text("Orvian vous permet de parcourir, organiser et consulter vos fichiers.")
        }
    }

    // MARK: - Chargement

    private func recentFailure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(recentUploads.isEmpty ? "Chargement impossible" : "Actualisation impossible",
                  systemImage: "wifi.exclamationmark")
                .font(.subheadline.weight(.semibold))
            Text(message).font(.footnote).foregroundStyle(.secondary)
            Button("Réessayer") {
                Task { await loadPreviews(forceNetwork: true) }
            }
            .frame(minHeight: 44)
        }
    }

    /// Ordre déterministe de l'aperçu : date décroissante, `id` décroissant
    /// en cas d'égalité. Les horodatages kDrive sont à la seconde : les
    /// imports en rafale partagent la même seconde et l'ordre serveur des
    /// ex æquo n'est pas garanti d'une requête `last_modified` à l'autre.
    /// Sans ce tri, les 3 cartes visibles (`prefix(3)`) permutent ~1 s après
    /// l'affichage du cache, alors même que le jeu de fichiers est identique.
    /// Le tri vit ici (aperçu seul), jamais dans le magasin partagé : trier
    /// la première page casserait la pagination au curseur de « voir plus ».
    private static func previewOrder(_ files: [DriveFile]) -> [DriveFile] {
        files.sorted {
            let lhs = $0.updatedAt ?? $0.lastModifiedAt ?? $0.addedAt ?? 0
            let rhs = $1.updatedAt ?? $1.lastModifiedAt ?? $1.addedAt ?? 0
            if lhs != rhs { return lhs > rhs }
            return $0.id > $1.id
        }
    }

    private func loadPreviews(forceNetwork: Bool = false) async {
        let requestID = UUID()
        previewRequestID = requestID
        guard let drive = session.selectedDrive,
              let credential = TokenStore.credentialFingerprint() else {
            recentUploads = []
            recentError = nil
            isLoadingRecents = false
            previewDriveId = nil
            previewCredential = nil
            return
        }
        if previewDriveId != drive.id || previewCredential != credential {
            recentUploads = []
            recentError = nil
            isLoadingRecents = true
            previewDriveId = drive.id
            previewCredential = credential
        }
        func isCurrentRequest() -> Bool {
            !Task.isCancelled && previewRequestID == requestID
                && session.selectedDrive?.id == drive.id
                && TokenStore.credentialFingerprint() == credential
        }

        // Mémoire puis disque : les cartes connues apparaissent avant la
        // requête `last_modified`, y compris au premier accès après lancement.
        if !forceNetwork, let snapshot = await recentUploadsLoader.cachedSnapshot(driveId: drive.id) {
            guard isCurrentRequest() else { return }
            recentUploads = Self.previewOrder(snapshot.items.filter { !$0.isDirectory })
            isLoadingRecents = false
        }

        guard isCurrentRequest() else { return }
        if recentUploads.isEmpty {
            isLoadingRecents = true
            recentError = nil
        }
        if let outcome = await recentUploadsLoader.refreshOutcome(
            driveId: drive.id, forceNetwork: forceNetwork
        ) {
            guard isCurrentRequest() else { return }
            if let snapshot = outcome.snapshot {
                recentUploads = Self.previewOrder(snapshot.items.filter { !$0.isDirectory })
            }
            recentError = outcome.error.map { ($0 as? APIError)?.errorDescription ?? $0.localizedDescription }
        }
        guard isCurrentRequest() else { return }
        isLoadingRecents = false
    }

    private func mergeUploaded(_ files: [DriveFile]) {
        guard previewDriveId == session.selectedDrive?.id,
              previewCredential == TokenStore.credentialFingerprint() else { return }
        let files = files.filter { !$0.isDirectory }
        let uploadedIDs = Set(files.map(\.id))
        recentUploads = Array(Self.previewOrder(
            files + recentUploads.filter { !uploadedIDs.contains($0.id) }
        ).prefix(12))
        isLoadingRecents = false
    }
}

// MARK: - Ligne de lien d'une carte iPad

/// Ligne cliquable d'une carte iPad : le chevron signale ce qui répond, et la
/// ligne entière est tapable (la « Version » voisine, elle, ne l'est pas).
private struct LinkRowLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
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

                        if let thumb = ThumbnailProvider.shared.cachedMemoryThumbnail(
                            driveId: driveId,
                            fileId: file.id,
                            isTrashed: false
                        ) {
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
