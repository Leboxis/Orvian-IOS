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
}
