import Foundation

/// Detecta que el usuario se salió de la ruta y dispara el recálculo (SCRUM-26).
///
/// - Sigue la ubicación mientras hay ruta activa (la misma fuente de GPS que la llegada).
/// - Se desvía cuando `DeviationPolicy.requiredConsecutiveFixes` lecturas precisas seguidas
///   quedan a más de `offRouteThresholdMeters` del trayecto. Las imprecisas no cuentan ni
///   reinician; una precisa sobre el trayecto reinicia todo (también los fallos).
/// - Entre dos recálculos automáticos espera `cooldownSeconds`. Tras
///   `maximumConsecutiveFailures` fallos seguidos deja de intentar hasta que el usuario
///   vuelva al trayecto; a mano siempre se puede.
/// - Sin red no intenta: espera a que vuelva la conexión y, si sigue desviado, recalcula.
@MainActor
final class RouteDeviationMonitor: RouteDeviationMonitoring {
    var onStatusChange: (@MainActor (RerouteStatus?) -> Void)?

    private let tracker: any LocationTracking
    private let store: any ActiveRouteStoring
    private let rerouter: any RouteRerouting
    private let connectivity: any ConnectivityObserving
    private let policy: DeviationPolicy
    private let now: () -> Date

    private var isMonitoring = false
    private var isRerouting = false
    private var trackedRoute: (id: UUID, revision: Int)?
    private var consecutiveOffRouteFixes = 0
    /// El usuario está desviado: se alcanzó el número de lecturas y aún no volvió.
    private var isDeviated = false
    /// Ya se avisó «Te saliste de la ruta» en esta desviación.
    private var hasAnnouncedDeviation = false
    private var consecutiveFailures = 0
    private var isWaitingForConnection = false
    private var lastAttemptAt: Date?
    private var status: RerouteStatus?

    init(
        tracker: any LocationTracking,
        store: any ActiveRouteStoring,
        rerouter: any RouteRerouting,
        connectivity: any ConnectivityObserving,
        policy: DeviationPolicy = DeviationPolicy(),
        now: @escaping () -> Date = Date.init
    ) {
        self.tracker = tracker
        self.store = store
        self.rerouter = rerouter
        self.connectivity = connectivity
        self.policy = policy
        self.now = now
        tracker.onFix = { [weak self] fix in
            Task { @MainActor in await self?.handle(fix) }
        }
        connectivity.start { [weak self] in
            Task { @MainActor in await self?.connectionRestored() }
        }
    }

    func startMonitoring() {
        guard !isMonitoring, let route = try? store.load() else { return }
        isMonitoring = true
        track(route)
        tracker.start()
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        trackedRoute = nil
        resetDeviation()
        tracker.stop()
        publish(nil)
    }

    @discardableResult
    func rerouteNow() async -> RerouteOutcome? {
        guard !isRerouting else { return nil }
        return await attempt(.manual)
    }

    func handle(_ fix: LocationFix) async {
        guard isMonitoring, !isRerouting else { return }
        guard let route = try? store.load() else {
            // La ruta terminó por otro camino (a mano, al llegar, al cerrar sesión).
            stopMonitoring()
            return
        }
        if trackedRoute?.id != route.id || trackedRoute?.revision != route.revision {
            // Ruta nueva, otro destino o recorrido recalculado: la desviación empieza de cero.
            track(route)
        }
        guard let isOffRoute = policy.isOffRoute(fix, route: route) else { return }
        guard isOffRoute else {
            // De vuelta en el trayecto. La confirmación «Ruta recalculada» se queda en pantalla.
            if case .rerouted = status {
                resetDeviation()
            } else if isDeviated || consecutiveOffRouteFixes > 0 || status != nil {
                resetDeviation()
                publish(nil)
            }
            return
        }
        consecutiveOffRouteFixes += 1
        guard consecutiveOffRouteFixes >= policy.requiredConsecutiveFixes else { return }
        isDeviated = true

        if isWaitingForConnection {
            // Por si el aviso de reconexión se perdió.
            guard connectivity.isConnected else { return }
            await attempt(.reconnected)
            return
        }
        guard consecutiveFailures < policy.maximumConsecutiveFailures, cooldownElapsed else { return }
        await attempt(hasAnnouncedDeviation ? .retry : .deviation)
    }

    /// Volvió la red: si sigue desviado y esperaba la conexión, recalcula ya.
    func connectionRestored() async {
        guard isMonitoring, isWaitingForConnection, isDeviated, !isRerouting else { return }
        await attempt(.reconnected)
    }

    // MARK: Apoyo

    @discardableResult
    private func attempt(_ trigger: RerouteTrigger) async -> RerouteOutcome {
        isRerouting = true
        lastAttemptAt = now()
        if trigger != .retry { hasAnnouncedDeviation = true }
        publish(.rerouting)
        let outcome = await rerouter.reroute(trigger: trigger)
        isRerouting = false

        switch outcome {
        case .rerouted(let route):
            resetDeviation()
            track(route)
            publish(.rerouted(route))
        case .offline:
            isWaitingForConnection = true
            publish(destination().map { .waitingForConnection(destination: $0) })
        case .failed(let error):
            consecutiveFailures += 1
            let retry: RerouteRetry = !isDeviated ? .none
                : consecutiveFailures < policy.maximumConsecutiveFailures ? .automatic : .stopped
            publish(.failed(error, destination: destination(), retry: retry))
        case .superseded:
            resetDeviation()
            publish(nil)
        case .noActiveRoute:
            publish(nil)
            stopMonitoring()
        }
        return outcome
    }

    private var cooldownElapsed: Bool {
        guard let lastAttemptAt else { return true }
        return now().timeIntervalSince(lastAttemptAt) >= policy.cooldownSeconds
    }

    private func track(_ route: ActiveRoute) {
        trackedRoute = (route.id, route.revision)
        resetDeviation()
    }

    private func resetDeviation() {
        consecutiveOffRouteFixes = 0
        isDeviated = false
        hasAnnouncedDeviation = false
        consecutiveFailures = 0
        isWaitingForConnection = false
    }

    private func destination() -> String? {
        (try? store.load())?.destination.name
    }

    private func publish(_ status: RerouteStatus?) {
        guard status != self.status else { return }
        self.status = status
        onStatusChange?(status)
    }
}

/// Plataformas sin seguimiento de ubicación.
final class NoDeviationMonitoring: RouteDeviationMonitoring {
    var onStatusChange: (@MainActor (RerouteStatus?) -> Void)?
    func startMonitoring() {}
    func stopMonitoring() {}
    func rerouteNow() async -> RerouteOutcome? { nil }
}
