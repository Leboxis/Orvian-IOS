import Foundation
import os

/// Mesure de performance réseau : chaque requête de l'`APIClient` est
/// chronométrée et journalisée, avec signpost System Trace pour Instruments
/// (subsystem `com.orvian.perf`, intervalle `request`).
///
/// L'app étant distribuée en LiveContainer, les mesures sont aussi lisibles
/// directement dans l'app : Profil → Réseau (dernières requêtes, durées,
/// codes HTTP, moyennes par endpoint). Le journal reste en mémoire
/// (capacité bornée), rien n'est écrit sur disque.
@MainActor
final class Perf: ObservableObject {
    static let shared = Perf()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        /// Date de fin de la requête.
        let date: Date
        let method: String
        let path: String
        let status: Int
        /// Durée complète de l'appel réseau, en millisecondes.
        let durationMs: Int
        let bytes: Int
        /// Réponse servie par le cache HTTP (fraîche, ou revalidée par un
        /// 304) : aucun corps transféré, coût quasi nul.
        let fromCache: Bool

        /// Nom court de l'endpoint pour les statistiques groupées
        /// (ex. `/3/drive/1/files/832/count` → `count`). Les chemins se
        /// terminant par un identifiant (fiche, mutation) sont regroupés
        /// sous leur ressource : `files/{id}`.
        var endpointName: String {
            let parts = path.split(separator: "/").map(String.init)
            guard let last = parts.last else { return path }
            if last.allSatisfy(\.isNumber) {
                let resource = parts.dropLast().last ?? last
                return "\(resource)/{id}"
            }
            return last
        }

        var isThumbnail: Bool { path.contains("/thumbnail") }
    }

    /// Journal borné : les 400 dernières requêtes, miniatures exclues.
    @Published private(set) var entries: [Entry] = []
    private var allEntries: [Entry] = []
    private let capacity = 400

    private init() {}

    func record(method: String, path: String, status: Int, durationMs: Int, bytes: Int, fromCache: Bool = false) {
        let entry = Entry(
            date: Date(),
            method: method,
            path: path,
            status: status,
            durationMs: durationMs,
            bytes: bytes,
            fromCache: fromCache
        )
        allEntries.append(entry)
        if allEntries.count > capacity {
            allEntries.removeFirst(allEntries.count - capacity)
        }
        // Les miniatures (par dizaines par grille) noieraient le journal :
        // elles comptent dans les statistiques mais ne sont pas listées.
        entries = allEntries.filter { !$0.isThumbnail }
    }

    func reset() {
        allEntries = []
        entries = []
    }

    // MARK: - Statistiques

    /// Nombre d'appels et durées moyennes par endpoint, pour repérer
    /// celui qui pèse (ex. `count` lent, `files` rechargé trop souvent).
    var statsByEndpoint: [(name: String, count: Int, averageMs: Int, maxMs: Int)] {
        let groups = Dictionary(grouping: allEntries) { $0.endpointName }
        return groups.map { name, list in
            let durations = list.map(\.durationMs)
            return (
                name: name,
                count: list.count,
                averageMs: durations.reduce(0, +) / max(durations.count, 1),
                maxMs: durations.max() ?? 0
            )
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.averageMs > $1.averageMs }
    }

    /// Durée moyenne des requêtes, miniatures exclues.
    var averageMs: Int {
        let main = allEntries.filter { !$0.isThumbnail }
        guard !main.isEmpty else { return 0 }
        return main.map(\.durationMs).reduce(0, +) / main.count
    }

    var totalRequests: Int { allEntries.count }
    var thumbnailRequests: Int { allEntries.filter(\.isThumbnail).count }
    var cachedRequests: Int { allEntries.filter(\.fromCache).count }
}

/// Chronomètre un appel réseau : signpost + journal. Le bloc `operation`
/// s'exécute dans le contexte d'isolation de l'appelant (l'actor
/// `APIClient`) et renvoie la valeur, le code HTTP et les octets reçus.
enum PerfTimer {
    /// Signposts System Trace (visibles dans Instruments sur un Mac),
    /// isolés du `@MainActor` de `Perf` : l'actor les lit directement.
    private static let signposter = OSSignposter(
        subsystem: "com.orvian.perf",
        category: "network"
    )

    static func measure<T>(
        method: String,
        path: String,
        operation: () async throws -> (T, status: Int, bytes: Int, fromCache: Bool)
    ) async throws -> T {
        let signposter = signposter
        let state = signposter.beginInterval("request", id: signposter.makeSignpostID())
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (value, status, bytes, fromCache) = try await operation()
            let elapsed = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
            signposter.endInterval("request", state)
            await Perf.shared.record(
                method: method,
                path: path,
                status: status,
                durationMs: elapsed,
                bytes: bytes,
                fromCache: fromCache
            )
            return value
        } catch {
            let elapsed = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
            signposter.endInterval("request", state)
            await Perf.shared.record(
                method: method,
                path: path,
                status: 0,
                durationMs: elapsed,
                bytes: 0
            )
            throw error
        }
    }
}
