import SwiftUI

/// Carte de fichier : miniature, étoile favori, nom, taille.
struct FileCardView: View {
    let file: DriveFile
    let driveId: Int
    var enabled = true
    var onToggleFavorite: (() -> Void)?
    var action: () -> Void

    @State private var thumbnail: UIImage?
    @State private var thumbnailLoaded = false

    private var kind: FileKind { file.fileKind }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                thumbnailArea
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .topTrailing) { favoriteBadge }
                    .overlay(alignment: .center) { playBadge }
                    .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)

                Text(file.name)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
            .opacity(enabled ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .task(id: file.id) {
            await loadThumbnail()
        }
    }

    // MARK: - Zones

    @ViewBuilder
    private var thumbnailArea: some View {
        let shape = RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(.black.opacity(0.05), lineWidth: 0.5)
                }
                .transition(.opacity)
        } else if thumbnailLoaded {
            // Fichier sans miniature : vignette typée, teinte très légère.
            ZStack {
                shape.fill(kind.tint.opacity(0.10))
                shape.strokeBorder(kind.tint.opacity(0.16), lineWidth: 0.8)
                Image(systemName: kind.symbolName)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(kind.tint)
                    .padding(14)
            }
        } else {
            ZStack {
                shape.fill(.quaternary.opacity(0.5))
                if kind == .folder {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(kind.tint.opacity(0.8))
                        .padding(14)
                }
            }
        }
    }

    private var subtitle: String {
        if file.isDirectory { return "Dossier" }
        return ByteFormatter.string(fromBytes: file.size)
    }

    /// Pastille translucide + étoile, lisible sur toute miniature.
    @ViewBuilder
    private var favoriteBadge: some View {
        if file.isFavorite == true {
            Button {
                onToggleFavorite?()
            } label: {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle().strokeBorder(.black.opacity(0.06), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retirer des favoris")
            .padding(5)
        }
    }

    /// Indicateur de lecture sur les vidéos.
    @ViewBuilder
    private var playBadge: some View {
        if file.isVideo {
            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        }
    }

    // MARK: - Miniature

    private func loadThumbnail() async {
        guard kind.supportsThumbnail else {
            thumbnailLoaded = true
            return
        }
        if let image = await ThumbnailProvider.shared.thumbnail(driveId: driveId, fileId: file.id) {
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                thumbnail = image
                thumbnailLoaded = true
            }
        } else {
            thumbnailLoaded = true
        }
    }
}
