import Foundation
import Network

/// État réseau minimal utilisé pour éviter les préchargements sur une
/// connexion facturée lorsque l'utilisateur le demande.
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.orvian.network-monitor")
    private let lock = NSLock()
    private var currentPath: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.lock()
            self?.currentPath = path
            self?.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    /// N'autorise le préchargement que sur une connexion Wi-Fi confirmée.
    /// Tant que l'état réseau n'est pas connu, aucune donnée anticipée n'est consommée.
    var allowsBackgroundPrefetch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentPath?.usesInterfaceType(.wifi) ?? false
    }

    /// Vrai uniquement quand on SAIT que la connexion n'est pas du Wi-Fi.
    /// Tant que l'état est inconnu (premières secondes après l'ouverture),
    /// on suppose le Wi-Fi : la première vidéo ne doit pas être pénalisée
    /// par une petite réserve alors qu'on est en réalité sur Wi-Fi.
    /// (Le préchargement anticipé, lui, reste bloqué tant que ce n'est pas
    /// confirmé — ne pas confondre prudence sur l'anticipé et qualité du direct.)
    var isKnownNonWiFi: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let path = currentPath else { return false }
        return !path.usesInterfaceType(.wifi)
    }
}
