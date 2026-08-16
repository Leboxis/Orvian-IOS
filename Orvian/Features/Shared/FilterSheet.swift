import SwiftUI

/// Feuille de filtres : tri, orientation vidéo (icônes seules) et type de média.
struct FilterSheet: View {
    @Binding var filters: FileFilters
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Trier par") {
                    ForEach(FileFilters.SortMode.allCases) { mode in
                        sortRow(mode)
                    }
                }

                Section("Orientation vidéo") {
                    HStack(spacing: 12) {
                        ForEach(FileFilters.Orientation.allCases) { orientation in
                            orientationButton(orientation)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                Section("Afficher") {
                    ForEach(FileFilters.MediaFilter.allCases) { media in
                        mediaRow(media)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        filters = FileFilters()
                    } label: {
                        Label("Réinitialiser", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("Filtres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Terminé") { dismiss() }
                }
            }
        }
    }

    private func sortRow(_ mode: FileFilters.SortMode) -> some View {
        Button {
            filters.sort = mode
        } label: {
            HStack {
                Label(mode.title, systemImage: mode.symbol)
                    .foregroundStyle(.primary)
                Spacer()
                if filters.sort == mode {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func mediaRow(_ media: FileFilters.MediaFilter) -> some View {
        Button {
            filters.media = media
        } label: {
            HStack {
                Text(media.title)
                    .foregroundStyle(.primary)
                Spacer()
                if filters.media == media {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func orientationButton(_ orientation: FileFilters.Orientation) -> some View {
        let isActive = filters.orientations.contains(orientation)
        return Button {
            if isActive {
                filters.orientations.remove(orientation)
            } else {
                filters.orientations.insert(orientation)
            }
        } label: {
            Image(systemName: orientation.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    isActive ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isActive ? Color.accentColor.opacity(0.4) : Color.gray.opacity(0.3), lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(orientation.title)
    }
}