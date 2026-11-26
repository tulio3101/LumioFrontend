import Foundation

/// Escucha la fuente de GPS compartida sin encenderla: recibe las lecturas mientras algún
/// cliente la mantiene encendida (durante la ruta activa). Lo usa Guiar Giros (SCRUM-312).
@MainActor
protocol RouteTrackingObserving: AnyObject {
    /// La fuente se encendió: empieza la ruta (o se restauró).
    func trackingDidStart()
    /// La fuente se apagó: la ruta terminó.
    func trackingDidStop()
    func receive(_ fix: LocationFix)
}

/// Una sola fuente de GPS para varios consumidores durante la ruta: la detección de llegada
/// (SCRUM-127) y la de desviación (SCRUM-26). Cada uno recibe su propio `LocationTracking`;
/// la fuente sigue mientras al menos uno lo tenga encendido. Los observadores (Guiar Giros,
/// SCRUM-312) reciben las mismas lecturas mientras la fuente esté encendida.
@MainActor
final class SharedLocationTracker {
    private let base: any LocationTracking
    private var clients: [Client] = []
    /// Fuertes a propósito: la fuente es quien mantiene vivo al observador.
    private var observers: [any RouteTrackingObserving] = []
    private var isRunning = false

    init(base: any LocationTracking) {
        self.base = base
        base.onFix = { [weak self] fix in self?.broadcast(fix) }
    }

    func makeClient() -> any LocationTracking {
        let client = Client(owner: self)
        clients.append(client)
        return client
    }

    func addObserver(_ observer: any RouteTrackingObserving) {
        observers.append(observer)
        if isRunning { observer.trackingDidStart() }
    }

    fileprivate func clientDidStart() {
        guard !isRunning, clients.contains(where: \.isRunning) else { return }
        isRunning = true
        base.start()
        for observer in observers { observer.trackingDidStart() }
    }

    fileprivate func clientDidStop() {
        guard isRunning, !clients.contains(where: \.isRunning) else { return }
        isRunning = false
        base.stop()
        for observer in observers { observer.trackingDidStop() }
    }

    private func broadcast(_ fix: LocationFix) {
        for client in clients where client.isRunning {
            client.onFix?(fix)
        }
        guard isRunning else { return }
        for observer in observers { observer.receive(fix) }
    }

    @MainActor
    private final class Client: LocationTracking {
        var onFix: ((LocationFix) -> Void)?
        private(set) var isRunning = false
        /// Fuerte a propósito: quien solo guarda los clientes mantiene viva la fuente.
        private let owner: SharedLocationTracker

        init(owner: SharedLocationTracker) {
            self.owner = owner
        }

        func start() {
            guard !isRunning else { return }
            isRunning = true
            owner.clientDidStart()
        }

        func stop() {
            guard isRunning else { return }
            isRunning = false
            owner.clientDidStop()
        }
    }
}
