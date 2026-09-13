import ActivityKit
import Foundation

/// Pilote la Live Activity d'upload (Dynamic Island + écran verrouillé).
/// Une seule activité agrégée : démarrée au premier fichier actif, mise à
/// jour uniquement quand le % affiché ou le libellé change (le système
/// limite le débit des updates), terminée quand il n'y a plus d'actifs.
@MainActor
final class UploadLiveActivityController {
    static let shared = UploadLiveActivityController()

    private var activity: Activity<UploadActivityAttributes>?
    private var lastPercent = -1
    private var lastFileName = ""
    private var lastCounts = ""

    private init() {}

    /// Resynchronise l'activité avec l'état courant d'`UploadManager`.
    func sync(tasks: [UploadTaskItem], overallProgress: Double) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let active = tasks.filter { $0.status.isActive }
        guard !active.isEmpty else {
            end()
            return
        }
        let percent = Int((overallProgress * 100).rounded())
        let firstName = active[0].fileName
        let counts = "\(active.count)/\(tasks.count)"
        guard activity == nil
            || percent != lastPercent
            || firstName != lastFileName
            || counts != lastCounts
        else { return }
        lastPercent = percent
        lastFileName = firstName
        lastCounts = counts

        let state = UploadActivityAttributes.ContentState(
            fileName: firstName,
            progress: min(max(overallProgress, 0), 1),
            activeCount: active.count,
            totalCount: tasks.count
        )
        let content = ActivityContent(state: state, staleDate: Date(timeIntervalSinceNow: 3600))
        if let activity {
            Task { await activity.update(content) }
        } else {
            Task { [weak self] in
                do {
                    self?.activity = try await Activity.request(
                        attributes: UploadActivityAttributes(title: "Envoi en cours"),
                        content: content
                    )
                } catch {
                    self?.activity = nil
                }
            }
        }
    }

    /// Termine l'activité (fin des uploads, annulation, déconnexion).
    func end() {
        lastPercent = -1
        lastFileName = ""
        lastCounts = ""
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}

extension UploadStatus {
    /// Vrai tant que le fichier participe à la progression globale.
    var isActive: Bool {
        switch self {
        case .queued, .inProgress: return true
        case .completed, .failed: return false
        }
    }
}
