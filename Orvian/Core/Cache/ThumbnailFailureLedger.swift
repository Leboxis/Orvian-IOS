import Foundation

/// Politique du cache négatif des miniatures.
///
/// Isolé du réseau, de l'UI et d'UIKit : la décision « faut-il redemander une
/// miniature ? » est ainsi exécutable directement par les contrôles CI, qui
/// vérifient les deux règles apprises à l'usage :
///
/// - **absence prouvée** — le serveur a répondu qu'il n'a pas de miniature
///   (404/410, corps vide). L'absence est mémorisée pour `absenceTTL` : la
///   carte cesse de relancer la boucle de réessais sur un fichier qui n'aura
///   jamais d'aperçu (documents, archives…).
/// - **panne passagère** — réseau coupé, timeout, 429 ou 5xx. La clé n'est
///   écartée que quelques secondes (`transientTTL`). Sans cette distinction,
///   une simple coupure réseau condamnait la miniature pendant cinq minutes
///   alors qu'elle était disponible dès le retour du réseau.
///
/// La table reste bornée : au-delà de `limit` clés, la plus ancienne est
/// évincée (FIFO par date de marquage).
struct ThumbnailFailureLedger {
    /// Nature de l'échec mémorisé.
    enum Reason {
        /// Le serveur a prouvé qu'il n'a pas de miniature pour ce fichier.
        case absent
        /// Échec dont rien ne prouve qu'il est définitif.
        case transient
    }

    private struct Slot {
        let markedAt: Date
        let ttl: TimeInterval
        let reason: Reason
    }

    /// Durée pendant laquelle une absence prouvée n'est pas redemandée.
    let absenceTTL: TimeInterval
    /// Durée pendant laquelle une panne passagère n'est pas redemandée.
    let transientTTL: TimeInterval
    /// Nombre maximal de clés mémorisées.
    let limit: Int

    private var slots: [String: Slot] = [:]

    init(
        absenceTTL: TimeInterval = 5 * 60,
        transientTTL: TimeInterval = 30,
        limit: Int = 512
    ) {
        self.absenceTTL = absenceTTL
        self.transientTTL = transientTTL
        self.limit = limit
    }

    /// Vrai tant que la clé est écartée. `now` est injectable pour les tests.
    func isBlocked(_ storageKey: String, now: Date = Date()) -> Bool {
        guard let slot = slots[storageKey] else { return false }
        return now.timeIntervalSince(slot.markedAt) < slot.ttl
    }

    /// Motif du blocage, `nil` si la clé est libre (ou son délai écoulé).
    func blockedReason(_ storageKey: String, now: Date = Date()) -> Reason? {
        guard isBlocked(storageKey, now: now) else { return nil }
        return slots[storageKey]?.reason
    }

    /// Le serveur a confirmé l'absence de miniature : inutile de réessayer
    /// avant `absenceTTL`.
    mutating func markAbsent(_ storageKey: String, now: Date = Date()) {
        mark(storageKey, ttl: absenceTTL, reason: .absent, now: now)
    }

    /// Échec sans preuve d'absence : la clé est seulement écartée le temps
    /// d'éviter une rafale de réessais.
    mutating func markTransientFailure(_ storageKey: String, now: Date = Date()) {
        mark(storageKey, ttl: transientTTL, reason: .transient, now: now)
    }

    /// Une miniature obtenue (réseau ou lecture disque) annule le marqueur.
    mutating func clear(_ storageKey: String) {
        slots[storageKey] = nil
    }

    mutating func removeAll() {
        slots.removeAll()
    }

    private mutating func mark(_ storageKey: String, ttl: TimeInterval, reason: Reason, now: Date) {
        if slots.count >= limit, slots[storageKey] == nil,
           let oldest = slots.min(by: { $0.value.markedAt < $1.value.markedAt })?.key {
            slots[oldest] = nil
        }
        slots[storageKey] = Slot(markedAt: now, ttl: ttl, reason: reason)
    }
}