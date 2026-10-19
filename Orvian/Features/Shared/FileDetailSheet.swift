import SwiftUI

/// Compact metadata shared by the adaptive inspector and the phone sheet.
struct FileDetailSheet: View {
    let file: DriveFile
    let driveId: Int
    var isTrashed = false
    var inInspector = false
    var close: (() -> Void)?
    var preparedModel: FileDetailsViewModel?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth = 104
    @State private var localModel = FileDetailsViewModel()
    private var model: FileDetailsViewModel { preparedModel ?? localModel }
    @State private var thumbnail: UIImage?
    @State private var pixelSize: CGSize?
    @State private var videoInfo: VideoMetadataInfo?
    private var current: DriveFile { model.file?.id == file.id ? (model.file ?? file) : file }
    private var previewImage: UIImage? {
        thumbnail ?? ThumbnailProvider.shared.cachedMemoryThumbnail(
            driveId: driveId, fileId: file.id, isTrashed: isTrashed)
    }
    private var hasFacts: Bool {
        current.isDirectory || current.addedAt != nil || current.lastModifiedAt != nil || current.updatedAt != nil
            || pixelSize != nil || videoInfo != nil || model.infoError != nil
    }

    var body: some View {
        Group {
            if inInspector {
                VStack(spacing: 0) {
                    HStack {
                        Text("Détails").font(.headline)
                        Spacer()
                        closeButton
                    }
                    .padding(.horizontal, 20)
                    detailContent
                }
                .background(Color(uiColor: .systemGroupedBackground))
            } else {
                NavigationStack {
                    detailContent
                        .navigationTitle("Détails")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                closeButton
                            }
                        }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        // Independent tasks: file info must not delay the cached preview.
        .task(id: file) {
            await model.loadIfNeeded(file: file, driveId: driveId, isTrashed: isTrashed)
        }
        .task(id: file.id) {
            let credential = TokenStore.credentialFingerprint()
            thumbnail = nil
            if file.fileKind.supportsThumbnail && previewImage == nil {
                let image = await ThumbnailProvider.shared.thumbnail(driveId: driveId, fileId: file.id, isTrashed: isTrashed)
                guard !Task.isCancelled, credential == TokenStore.credentialFingerprint() else { return }
                thumbnail = image
            }
        }
        .task(id: file.id) {
            let credential = TokenStore.credentialFingerprint()
            pixelSize = nil
            videoInfo = nil
            if file.isImage && !isTrashed {
                let size = await HiresImageStore.shared.cachedOriginalPixelSize(driveId: driveId, fileId: file.id)
                guard !Task.isCancelled, credential == TokenStore.credentialFingerprint() else { return }
                pixelSize = size
            }
            if file.isVideo && !isTrashed {
                let info = await MediaMetadataStore.shared.cachedInfo(driveId: driveId, file: file)
                guard !Task.isCancelled, credential == TokenStore.credentialFingerprint() else { return }
                videoInfo = info
            }
        }
    }

    private var closeButton: some View {
        Button("Fermer", systemImage: "xmark") {
            if let close { close() } else { dismiss() }
        }
        .labelStyle(.iconOnly)
        .frame(minWidth: 44, minHeight: 44)
        .keyboardShortcut(.escape, modifiers: [])
    }

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identity
                facts
                organization
            }
            .padding(20)
            .frame(maxWidth: 540, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("file.details.content")
    }

    @ViewBuilder private var facts: some View {
        if hasFacts || model.isLoading {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Informations")
                if model.isLoading && !hasFacts { ProgressView("Actualisation…") }
                if current.isDirectory { folderSizeRow }
                if let date = current.addedAt { dateRow("Ajouté", date) }
                if let date = current.lastModifiedAt { dateRow("Contenu modifié", date) }
                if let date = current.updatedAt, date != current.lastModifiedAt { dateRow("Mis à jour", date) }
                if let pixelSize {
                    valueRow("Dimensions", "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px")
                }
                if !isTrashed, let video = videoInfo {
                    if video.duration.isFinite && video.duration > 0 {
                        valueRow("Durée", Duration.seconds(video.duration).formatted(.time(pattern: .hourMinuteSecond)))
                    }
                    if video.maximumDimension.isFinite && video.maximumDimension > 0 {
                        valueRow("Côté long", "\(Int(video.maximumDimension)) px")
                    }
                    valueRow("Orientation", video.orientation.rawValue == "portrait" ? "Portrait" : video.orientation.rawValue == "landscape" ? "Paysage" : "Carré")
                }
                if let error = model.infoError { recovery(error) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: DS.cardRadius))
        }
    }

    private var folderSizeRow: some View {
        detailRow("Poids total") {
            if isTrashed {
                Text("Non communiqué pour la corbeille").foregroundStyle(.secondary)
            } else if model.file?.id != file.id || model.isLoadingFolderSize {
                ProgressView("Chargement…")
            } else if let size = model.folderSize {
                Text(ByteFormatter.string(fromBytes: size)).textSelection(.enabled)
                Text("Sous-dossiers inclus, hors versions").font(.caption).foregroundStyle(.secondary)
            } else if let error = model.folderSizeError {
                recovery(error)
            } else {
                Text("Non communiqué").foregroundStyle(.secondary)
            }
        }
    }

    private var organization: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Organisation")
            if let path = current.path, !path.isEmpty {
                if (path as NSString).lastPathComponent == current.name {
                    let parent = (path as NSString).deletingLastPathComponent
                    valueRow("Dossier parent", parent.isEmpty || parent == "/" ? "Racine du drive" : (parent as NSString).lastPathComponent)
                }
                valueRow("Emplacement", path)
            } else {
                Text("Emplacement non communiqué").font(.subheadline).foregroundStyle(.secondary)
            }
            detailRow("Tags") {
                if model.isLoadingTags && model.categories.isEmpty {
                    ProgressView("Chargement…")
                } else if isTrashed {
                    Text("Élément dans la corbeille").font(.subheadline).foregroundStyle(.secondary)
                } else if model.categories.isEmpty && model.tagsError == nil {
                    Text("Aucun tag").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.categories) { category in
                            Label {
                                Text(category.name).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "tag.fill").foregroundStyle(Color(hex: category.color) ?? .accentColor)
                            }
                            .font(.footnote).padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.smallRadius))
                        }
                    }
                }
                if let error = model.tagsError { recovery(error) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: DS.cardRadius))
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.compactRadius).fill(current.fileKind.tint.opacity(0.12))
                if let previewImage {
                    Image(uiImage: previewImage).resizable().scaledToFill()
                } else {
                    Image(systemName: current.fileKind.symbolName).font(.title2).foregroundStyle(current.fileKind.tint)
                }
            }
            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: DS.compactRadius))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(current.name).font(.headline).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                Text([current.fileKind.label, current.fileExtension?.uppercased()]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                if let size = current.size, !current.isDirectory {
                    Text(ByteFormatter.string(fromBytes: size)).font(.subheadline).foregroundStyle(.secondary)
                }
                if current.isFavorite == true {
                    Label("Favori", systemImage: "star.fill").font(.caption).foregroundStyle(.secondary)
                }
                if isTrashed { Label("Dans la corbeille", systemImage: "trash").font(.caption) }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }
    private func valueRow(_ label: String, _ value: String) -> some View {
        detailRow(label) {
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func detailRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            Text(label).foregroundStyle(.secondary)
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : labelWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8, content: value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }
    private func dateRow(_ label: String, _ timestamp: Double) -> some View {
        valueRow(label, Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened))
    }
    private func recovery(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message).font(.footnote).foregroundStyle(.secondary)
            Button("Réessayer") { Task { await model.load(file: file, driveId: driveId, isTrashed: isTrashed) } }
                .frame(minHeight: 44)
                .disabled(model.isLoading)
        }
    }
}
