import ActivityKit
import Foundation

/// Attributs de la Live Activity d'upload, partagés entre l'app et
/// l'extension widget (le fichier est compilé dans les deux targets).
/// Une seule activité agrégée : elle reflète `overallProgress` quel que soit
/// le parallélisme (4 uploads max côté `UploadManager`).
struct UploadActivityAttributes: ActivityAttributes {
    /// État dynamique : tout ce qui change pendant l'envoi.
    struct ContentState: Codable, Hashable {
        /// Nom du premier fichier actif ( complété par le compteur en vue).
        var fileName: String
        /// Progression globale 0.0 → 1.0 (même convention que la bulle in-app).
        var progress: Double
        /// Fichiers encore en cours d'envoi.
        var activeCount: Int
        /// Fichiers du lot (actifs + terminés + échoués).
        var totalCount: Int
    }

    /// Données figées à la création (titre affiché sur l'écran verrouillé).
    var title: String
}
