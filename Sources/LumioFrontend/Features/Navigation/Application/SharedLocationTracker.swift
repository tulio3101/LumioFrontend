import Foundation

/// Una sola fuente de GPS para varios consumidores durante la ruta: la detección de llegada
/// (SCRUM-127) y la de desviación (SCRUM-26). Cada uno recibe su propio `LocationTracking`;
/// la fuente sigue mientras al menos uno lo tenga encendido.
@MainActor
final class SharedLocationTracker {
    private let base: any LocationTracking
    private var clients: [Client] = []

    init(base: any LocationTracking) {
        self.base = base
        base.onFix = { [weak self] fix in self?.broadcast(fix) }
    }

    func makeClient() -> any LocationTracking {
        let client = Client(owner: self)
        clients.append(client)
        return client
    }

    fileprivate func clientDidStart() {
        if clients.filter(\.isRunning).count == 1 { base.start() }
    }

    fileprivate func clientDidStop() {
        if !clients.contains(where: \.isRunning) { base.stop() }
    }

    private func broadcast(_ fix: LocationFix) {
        for client in clients where client.isRunning {
            client.onFix?(fix)
        }
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
