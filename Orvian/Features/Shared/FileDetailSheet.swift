import SwiftUI

/// Inspecteur informatif : les opérations restent dans le menu contextuel du fichier.
struct FileDetailSheet: View {
    let file: DriveFile
    let driveId: Int
    var isTrashed = false
    @Environment(\.dismiss) private var dismiss
    @State private var model = FileDetailsViewModel()
    @State private var thumbnail: UIImage?
    @State private var pixelSize: CGSize?
    @State private var videoInfo: VideoMetadataInfo?
    private var current: DriveFile { model.file ?? file }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    identity
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("Repères")
                        if let date = current.addedAt { dateRow("Ajouté", date) }
                        if let date = current.updatedAt ?? current.lastModifiedAt { dateRow("Modifié", date) }
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
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("Organisation")
                        if let path = current.path, !path.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Emplacement").font(.caption).foregroundStyle(.secondary)
                                Text(path).font(.subheadline).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("Tags").font(.caption).foregroundStyle(.secondary)
                        if model.isLoading {
                            ProgressView("Chargement…")
                        } else if let error = model.tagsError {
                            recovery(error)
                        } else if isTrashed {
                            Text("Élément dans la corbeille").font(.subheadline).foregroundStyle(.secondary)
                        } else if model.categories.isEmpty {
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
                                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: DS.smallRadius))
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 540, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Détails")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer", systemImage: "xmark") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
        .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
        .presentationDetents([.medium, .large])
        .task(id: file) {
            thumbnail = nil
            pixelSize = nil
            videoInfo = nil
            await model.load(file: file, driveId: driveId, isTrashed: isTrashed)
            guard !Task.isCancelled else { return }
            if file.isImage && !isTrashed {
                pixelSize = await HiresImageStore.shared.cachedOriginalPixelSize(driveId: driveId, fileId: file.id)
            }
            if file.fileKind.supportsThumbnail {
                let image = await ThumbnailProvider.shared.thumbnail(driveId: driveId, fileId: file.id, isTrashed: isTrashed)
                guard !Task.isCancelled else { return }
                thumbnail = image
            }
            if file.isVideo && !isTrashed {
                await MediaMetadataStore.shared.resolveAll(driveId: driveId, items: [file])
                guard !Task.isCancelled else { return }
                videoInfo = MediaMetadataStore.shared.info(driveId: driveId, for: file.id)
            }
        }
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
                Text(current.fileKind.label).font(.subheadline).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).textSelection(.enabled)
        }
    }
    private func dateRow(_ label: String, _ timestamp: Double) -> some View {
        valueRow(label, Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened))
    }
    private func recovery(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message).font(.footnote).foregroundStyle(.secondary)
            Button("Réessayer") { Task { await model.load(file: file, driveId: driveId, isTrashed: isTrashed) } }
                .frame(minHeight: 44)
        }
    }
}
