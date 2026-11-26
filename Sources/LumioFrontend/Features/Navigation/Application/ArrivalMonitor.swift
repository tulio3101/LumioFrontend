import Foundation

/// Detecta la llegada al destino (SCRUM-127) y finaliza la ruta como completada.
///
/// Sigue la ubicación mientras hay ruta activa, también con el teléfono bloqueado. Llega
/// cuando `ArrivalPolicy.requiredConsecutiveFixes` lecturas precisas seguidas caen dentro
/// del radio del destino: un salto del GPS no basta. Las lecturas imprecisas no cuentan ni
/// reinician la cuenta; una precisa lejos del destino sí la reinicia. Si el destino cambia,
/// la cuenta empieza de nuevo.
@MainActor
final class ArrivalMonitor: ArrivalMonitoring {
    var onArrival: (@MainActor (RouteFinishResult) -> Void)?

    private let tracker: any LocationTracking
    private let store: any ActiveRouteStoring
    private let finisher: any RouteFinishing
    private let policy: ArrivalPolicy
    private var isMonitoring = false
    private var isFinishing = false
    private var consecutiveNearFixes = 0
    private var trackedRoute: (id: UUID, revision: Int)?

    init(
        tracker: any LocationTracking,
        store: any ActiveRouteStoring,
        finisher: any RouteFinishing,
        policy: ArrivalPolicy = ArrivalPolicy()
    ) {
        self.tracker = tracker
        self.store = store
        self.finisher = finisher
        self.policy = policy
        tracker.onFix = { [weak self] fix in
            Task { @MainActor in await self?.handle(fix) }
        }
    }

    func startMonitoring() {
        guard !isMonitoring, (try? store.load()) != nil else { return }
        isMonitoring = true
        consecutiveNearFixes = 0
        tracker.start()
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        consecutiveNearFixes = 0
        tracker.stop()
    }

    func handle(_ fix: LocationFix) async {
        guard isMonitoring, !isFinishing else { return }
        guard let route = try? store.load() else {
            // La ruta terminó por otro camino (a mano, al cerrar sesión): dejar de seguir.
            stopMonitoring()
            return
        }
        if trackedRoute?.id != route.id || trackedRoute?.revision != route.revision {
            trackedRoute = (route.id, route.revision)
            consecutiveNearFixes = 0
        }
        guard let isNear = policy.isNearDestination(fix, destination: route.destination) else { return }
        guard isNear else {
            consecutiveNearFixes = 0
            return
        }
        consecutiveNearFixes += 1
        guard consecutiveNearFixes >= policy.requiredConsecutiveFixes else { return }

        isFinishing = true
        stopMonitoring()
        let result = await finisher.finishActiveRoute(outcome: .completed, trigger: .arrival)
        isFinishing = false
        if let result { onArrival?(result) }
    }
}

/// Plataformas sin seguimiento de ubicación.
final class NoArrivalMonitoring: ArrivalMonitoring {
    var onArrival: (@MainActor (RouteFinishResult) -> Void)?
    func startMonitoring() {}
    func stopMonitoring() {}
}
