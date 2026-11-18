import Foundation

/// Estado de la conexión y aviso cuando vuelve, para reintentar lo pendiente (por ejemplo,
/// el historial de rutas finalizadas sin red o el recálculo de la ruta).
@MainActor
protocol ConnectivityObserving: AnyObject {
    /// false solo cuando se sabe que no hay red; antes de la primera lectura se asume que sí.
    var isConnected: Bool { get }
    /// Cada llamada añade un aviso; todos se ejecutan al volver la conexión.
    func start(onReconnect: @escaping @MainActor () -> Void)
}

/// Plataformas sin monitor de red: siempre conectado, nunca avisa.
final class AssumeConnected: ConnectivityObserving {
    var isConnected: Bool { true }
    func start(onReconnect: @escaping @MainActor () -> Void) {}
}

#if canImport(Network)
import Network

final class NetworkConnectivityMonitor: ConnectivityObserving {
    private let monitor = NWPathMonitor()
    private var wasConnected: Bool?
    private var handlers: [@MainActor () -> Void] = []
    private var isStarted = false

    var isConnected: Bool { wasConnected ?? true }

    func start(onReconnect: @escaping @MainActor () -> Void) {
        handlers.append(onReconnect)
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let reconnected = connected && self.wasConnected == false
                // Antes de avisar: quien reintenta lee `isConnected`.
                self.wasConnected = connected
                if reconnected {
                    for handler in self.handlers { handler() }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "lumio.connectivity"))
    }

    deinit {
        monitor.cancel()
    }
}
#endif
