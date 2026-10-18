import SwiftUI

/// Dimensions and encoded byte counts of thumbnails already received by this
/// device. This screen does not fetch originals or request new thumbnails.
struct ThumbnailInformationView: View {
    let driveId: Int
    @State private var information: [DiskImageCache.ThumbnailInformation] = []
    @State private var isLoading = true
    @State private var requestID = UUID()

    var body: some View {
        List {
            Section {
                Text("Dimensions réelles des miniatures reçues sur cet appareil, indépendamment de la taille des cartes.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } footer: {
                Text("Lecture des 100 miniatures les plus récentes du cache de ce drive. Aucun téléchargement supplémentaire.")
            }
            if isLoading {
                ProgressView("Lecture du cache…")
            } else if information.isEmpty {
                ContentUnavailableView("Aucune miniature en cache", systemImage: "photo",
                    description: Text("Affichez quelques fichiers dans le drive, puis revenez ici et actualisez."))
            } else {
                Section("\(information.count) miniature\(information.count > 1 ? "s" : "") mesurée\(information.count > 1 ? "s" : "")") {
                    ForEach(information) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(item.width) × \(item.height) pixels")
                                    .font(.headline).monospacedDigit()
                                Spacer(minLength: 8)
                                Text(ByteFormatter.string(fromBytes: item.byteCount))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text("Élément #\(item.fileId)\(item.isTrashed ? " · Corbeille" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Cache disque · \(item.cachedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle("Miniatures")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Actualiser", systemImage: "arrow.clockwise") { Task { await load() } }
                    .disabled(isLoading)
            }
        }
        .task(id: driveId) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let request = UUID()
        requestID = request
        isLoading = true
        let result = await ThumbnailProvider.shared.cachedInformation(driveId: driveId)
        guard !Task.isCancelled, requestID == request else { return }
        information = result
        isLoading = false
    }
}
