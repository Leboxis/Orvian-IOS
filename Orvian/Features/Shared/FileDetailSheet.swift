import SwiftUI

/// Compact metadata shared by the adaptive inspector and the phone sheet.
struct FileDetailSheet: View {
    let file: DriveFile
    let driveId: Int
    var isTrashed = false
    @Environment(\.dismiss) private var dismiss
    @State private var model = FileDetailsViewModel()
    @State private var thumbnail: UIImage?
    @State private var pixelSize: CGSize?
    @State private var videoInfo: VideoMetadataInfo?
    private var current: DriveFile { model.file?.id == file.id ? (model.file ?? file) : file }
    private var hasFacts: Bool {
        current.addedAt != nil || current.lastModifiedAt != nil || current.updatedAt != nil
            || pixelSize != nil || videoInfo != nil || model.infoError != nil
    }

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Détails")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // Independent tasks: file info must not delay the cached preview.
        .task(id: file) {
            await model.load(file: file, driveId: driveId, isTrashed: isTrashed)
        }
        .task(id: file.id) {
            let credential = TokenStore.credentialFingerprint()
            thumbnail = nil
            if file.fileKind.supportsThumbnail {
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

    @ViewBuilder private var facts: some View {
        if hasFacts || model.isLoading {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Informations")
            if model.isLoading && !hasFacts { ProgressView("Actualisation…") }
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

    private var organization: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Organisation")
            if let path = current.path, !path.isEmpty {
                if (path as NSString).lastPathComponent == current.name {
                    let parent = (path as NSString).deletingLastPathComponent
                    valueRow("Dossier parent", parent.isEmpty || parent == "/" ? "Racine du drive" : (parent as NSString).lastPathComponent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Emplacement").font(.caption).foregroundStyle(.secondary)
                    Text(path).font(.subheadline).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Emplacement non communiqué").font(.subheadline).foregroundStyle(.secondary)
            }
            Text("Tags").font(.caption).foregroundStyle(.secondary)
            if model.isLoading && model.categories.isEmpty {
                ProgressView("Chargement…")
            } else if isTrashed {
                Text("Élément dans la corbeille").font(.subheadline).foregroundStyle(.secondary)
            } else if model.categories.isEmpty && model.tagsError == nil {
                Text("Aucun tag").font(.subheadline).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading, spacing: 8) {
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: DS.cardRadius))
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.compactRadius).fill(current.fileKind.tint.opacity(0.12))
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 8)
                Text(value).textSelection(.enabled).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
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
