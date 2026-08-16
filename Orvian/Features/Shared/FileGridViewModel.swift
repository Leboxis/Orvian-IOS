import Foundation
import Observation

/// Vue-modèle partagé par toutes les grilles paginées
/// (Actualité, Fichiers, Favoris, Média).
@MainActor
@Observable
final class FileGridViewModel {
    private(set) var items: [DriveFile] = []
    private(set) var isInitialLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?

    private var cursor: String?
    private var loadedOnce = false

    let source: FileSource
    let driveId: Int
    private let service: KDriveService

    init(source: FileSource, driveId: Int, service: KDriveService = KDriveService()) {
        self.source = source
        self.driveId = driveId
        self.service = service
    }

    // MARK: - Chargement

    /// Charge au premier affichage de l'onglet uniquement.
    func loadIfNeeded() async {
        guard !loadedOnce, !isInitialLoading else { return }
        await reload()
    }

    /// Rafraîchit en conservant les anciennes cartes à l'écran.
    func reload() async {
        isInitialLoading = items.isEmpty
        errorMessage = nil
        do {
            let page = try await service.page(source, driveId: driveId, cursor: nil)
            guard !Task.isCancelled else { return }
            items = page.data ?? []
            cursor = page.cursor
            hasMore = page.hasMore ?? false
            loadedOnce = true
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
        isInitialLoading = false
    }

    /// Pagination infinie : déclenché par l'apparition des dernières cartes.
    func loadMoreIfNeeded() async {
        guard hasMore, !isLoadingMore, !isInitialLoading, errorMessage == nil else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.page(source, driveId: driveId, cursor: cursor)
            guard !Task.isCancelled else { return }
            let existing = Set(items.map(\.id))
            items.append(contentsOf: (page.data ?? []).filter { !existing.contains($0.id) })
            cursor = page.cursor
            hasMore = page.hasMore ?? false
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Favoris

    /// Bascule optimiste : l'étoile change immédiatement, retour arrière si l'API refuse.
    func toggleFavorite(_ file: DriveFile) async {
        guard let index = items.firstIndex(where: { $0.id == file.id }) else { return }
        let newValue = !(file.isFavorite ?? false)
        items[index].isFavorite = newValue
        do {
            try await service.setFavorite(driveId: driveId, fileId: file.id, favorite: newValue)
        } catch {
            items[index].isFavorite = file.isFavorite
            errorMessage = "Impossible de modifier le favori : \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: - Groupes (Actualité par jour, Média par mois)

    struct Group: Identifiable {
        let title: String
        let files: [DriveFile]
        var id: String { title }
    }

    func groups(calendar: Calendar = .current, by component: Calendar.Component, title: (Date) -> String) -> [Group] {
        var buckets: [(Date, [DriveFile])] = []
        for file in items {
            let date = Date(timeIntervalSince1970: file.lastModifiedAt ?? file.addedAt ?? 0)
            if let last = buckets.last, calendar.isDate(last.0, equalTo: date, toGranularity: component) {
                buckets[buckets.count - 1].1.append(file)
            } else {
                buckets.append((date, [file]))
            }
        }
        return buckets.map { Group(title: title($0.0), files: $0.1) }
    }

    /// « Aujourd'hui », « Hier », sinon la date complète localisée.
    static func dayTitle(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Aujourd'hui" }
        if calendar.isDateInYesterday(date) { return "Hier" }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
