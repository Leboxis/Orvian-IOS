import Foundation
import Combine
import os

/// Mesure de performance réseau : chaque requête de l'`APIClient` est
/// chronométrée et journalisée, avec signpost System Trace pour Instruments
/// (subsystem `com.orvian.perf`, intervalle `request`).
///
/// L'app étant distribuée en LiveContainer, les mesures sont aussi lisibles
/// directement dans l'app : Profil → Réseau (dernières requêtes, durées,
/// codes HTTP, moyennes par endpoint). Le journal reste en mémoire
/// (capacité bornée), rien n'est écrit sur disque.
///
/// `Perf` n'est **volontairement pas** isolé au MainActor : enregistrer une
/// requête ne nécessite pas de passage sur le MainActor (miniatures comprises).
/// Les compteurs vivent sous verrou et le résumé affiché est reconstruit hors
/// du MainActor **au plus une fois par `publishInterval`** (publication
/// groupée), ce qui réduit les mises à jour de l'écran de diagnostic.
final class Perf: ObservableObject, @unchecked Sendable {
    static let shared = Perf()

    struct Entry: Identifiable, Equatable, Sendable {
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

    /// Durées moyennes par endpoint (résumé publié vers l'interface).
    struct EndpointStat: Sendable {
        var name: String
        var count: Int
        var averageMs: Int
        var maxMs: Int
    }

    /// Photographie immuable du journal, prête à afficher.
    struct Summary: Sendable {
        var entries: [Entry] = []
        var statsByEndpoint: [EndpointStat] = []
        var averageMs: Int = 0
        var totalRequests: Int = 0
        var thumbnailRequests: Int = 0
        var cachedRequests: Int = 0
    }

    /// Dernier résumé publié : l'interface lit celui-ci, jamais les compteurs
    /// vivants, et n'est donc plus reconstruite au rythme des requêtes.
    @Published private(set) var summary = Summary()

    private let lock = NSLock()
    /// Journal borné : les 400 dernières requêtes, miniatures comprises (elles
    /// comptent dans les statistiques même si la liste les exclut).
    private var allEntries: [Entry] = []
    private var requestCount = 0
    private var thumbnailCount = 0
    private var cachedCount = 0
    private let capacity = 400
    /// Regroupe les publications : une rafale de miniatures ne provoque plus
    /// qu'une seule reconstruction du résumé.
    private let publishInterval = Duration.milliseconds(400)
    private var publishTask: Task<Void, Never>?
    private var needsPublish = false
    /// Incrémenté à chaque réinitialisation : une publication en vol devient
    /// obsolète et ne peut plus écraser le résumé vide.
    private var publishGeneration = 0

    private init() {}

    /// Enregistre une requête sous un verrou bref, sans attendre le MainActor.
    /// Le résumé est reconstruit en arrière-plan, avec publications groupées.
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
        lock.lock()
        allEntries.append(entry)
        if allEntries.count > capacity {
            allEntries.removeFirst(allEntries.count - capacity)
        }
        requestCount += 1
        if entry.isThumbnail { thumbnailCount += 1 }
        if fromCache { cachedCount += 1 }
        needsPublish = true
        lock.unlock()
        schedulePublish()
    }

    /// Vide le journal (bouton « Réinitialiser » de l'écran de diagnostic).
    @MainActor
    func reset() {
        lock.lock()
        allEntries.removeAll()
        requestCount = 0
        thumbnailCount = 0
        cachedCount = 0
        publishGeneration &+= 1
        publishTask?.cancel()
        publishTask = nil
        needsPublish = false
        lock.unlock()
        summary = Summary()
    }

    private func schedulePublish() {
        lock.lock()
        guard publishTask == nil, needsPublish else {
            lock.unlock()
            return
        }
        let generation = publishGeneration
        let interval = publishInterval
        publishTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch { return }
            guard let self, let snapshot = self.makeSummary(generation: generation) else { return }
            await self.publish(snapshot, generation: generation)
        }
        lock.unlock()
    }

    /// La validation et l'affectation sont sur le même acteur que reset() :
    /// aucune réinitialisation ne peut s'intercaler entre les deux.
    @MainActor
    private func publish(_ snapshot: Summary, generation: Int) {
        lock.lock()
        guard publishGeneration == generation else {
            lock.unlock()
            return
        }
        publishTask = nil
        lock.unlock()
        summary = snapshot
        // Les requêtes reçues pendant le calcul ou l'attente du MainActor
        // restent marquées et auront leur propre publication, même si le
        // trafic s'arrête maintenant.
        schedulePublish()
    }

    /// Construit le résumé à partir du journal : exécuté dans la tâche de
    /// publication, donc jamais sur le MainActor.
    private func makeSummary(generation: Int) -> Summary? {
        lock.lock()
        guard publishGeneration == generation else {
            lock.unlock()
            return nil
        }
        let entries = allEntries
        let total = requestCount
        let thumbnails = thumbnailCount
        let cached = cachedCount
        needsPublish = false
        lock.unlock()

        // Les miniatures (par dizaines par grille) noieraient la liste :
        // elles comptent dans les statistiques mais ne sont pas listées.
        let listed = entries.filter { !$0.isThumbnail }
        let average = listed.isEmpty ? 0 : listed.map(\.durationMs).reduce(0, +) / listed.count
        let stats = Dictionary(grouping: entries) { $0.endpointName }
            .map { name, list -> EndpointStat in
                let durations = list.map(\.durationMs)
                return EndpointStat(
                    name: name,
                    count: list.count,
                    averageMs: durations.reduce(0, +) / max(durations.count, 1),
                    maxMs: durations.max() ?? 0
                )
            }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.averageMs > $1.averageMs }

        return Summary(
            entries: listed,
            statsByEndpoint: stats,
            averageMs: average,
            totalRequests: total,
            thumbnailRequests: thumbnails,
            cachedRequests: cached
        )
    }

    // MARK: - Statistiques (lues par l'écran de diagnostic)

    /// Requêtes récentes, miniatures exclues (elles noieraient la liste).
    var entries: [Entry] { summary.entries }

    /// Nombre d'appels et durées moyennes par endpoint, pour repérer
    /// celui qui pèse (ex. `count` lent, `files` rechargé trop souvent).
    var statsByEndpoint: [EndpointStat] { summary.statsByEndpoint }

    /// Durée moyenne des requêtes, miniatures exclues.
    var averageMs: Int { summary.averageMs }

    var totalRequests: Int { summary.totalRequests }
    var thumbnailRequests: Int { summary.thumbnailRequests }
    var cachedRequests: Int { summary.cachedRequests }
}

/// Chronomètre un appel réseau : signpost + journal. Le bloc `operation`
/// s'exécute dans le contexte d'isolation de l'appelant (l'actor
/// `APIClient`) et renvoie la valeur, le code HTTP et les octets reçus.
enum PerfTimer {
    /// Réglage « Réglages → Diagnostic → Suivi des requêtes réseau ».
    /// Lu directement (dictionnaire en mémoire, aucun saut MainActor) :
    /// une lecture par requête reste négligeable. Absent = activé, pour
    /// conserver le comportement des versions antérieures.
    private static let isEnabledKey = "networkPerfEnabled"
    /// Clé partagée avec Réglages (`@AppStorage`).
    static let settingsKey = isEnabledKey
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: isEnabledKey) as? Bool ?? true
    }

    /// Signposts System Trace (visibles dans Instruments sur un Mac),
    /// isolés de l'isolation de `Perf` : l'actor les lit directement.
    private static let signposter = OSSignposter(
        subsystem: "com.orvian.perf",
        category: "network"
    )

    static func measure<T>(
        method: String,
        path: String,
        operation: () async throws -> (T, status: Int, bytes: Int, fromCache: Bool)
    ) async throws -> T {
        // Suivi désactivé : exécution directe — ni signpost, ni journal,
        // ni saut sur le MainActor. Aucune mesure n'est collectée.
        guard isEnabled else { return try await operation().0 }
        let signposter = signposter
        let state = signposter.beginInterval("request", id: signposter.makeSignpostID())
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (value, status, bytes, fromCache) = try await operation()
            let elapsed = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
            signposter.endInterval("request", state)
            Perf.shared.record(
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
            Perf.shared.record(
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
