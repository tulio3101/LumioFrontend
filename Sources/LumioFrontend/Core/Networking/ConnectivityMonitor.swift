import Foundation

/// Avisa cuando vuelve la conexión, para reintentar lo pendiente (por ejemplo, el historial
/// de rutas finalizadas sin red).
@MainActor
protocol ConnectivityObserving: AnyObject {
    func start(onReconnect: @escaping @MainActor () -> Void)
}

#if canImport(Network)
import Network

final class NetworkConnectivityMonitor: ConnectivityObserving {
    private let monitor = NWPathMonitor()
    private var wasConnected: Bool?

    func start(onReconnect: @escaping @MainActor () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                defer { self.wasConnected = connected }
                if connected, self.wasConnected == false { onReconnect() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "lumio.connectivity"))
    }

    deinit {
        monitor.cancel()
    }
}
#endif
