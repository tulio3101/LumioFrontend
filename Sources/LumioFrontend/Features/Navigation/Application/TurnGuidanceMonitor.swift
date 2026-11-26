import Foundation

/// Guiar Giros durante el Trayecto (SCRUM-312).
///
/// - Escucha la fuente de GPS compartida (`SharedLocationTracker`) mientras la siguen la
///   llegada y la desviación, es decir, mientras hay ruta activa; también con el teléfono
///   bloqueado.
/// - Usa solo la copia local de la ruta (`ActiveRouteStoring`): el backend no interviene.
/// - Con cada lectura precisa sobre el trayecto, `RouteProgressEstimator` dice qué maniobra
///   viene y a cuántos metros. `currentStep` avanza (solo hacia delante) para que «Repetir
///   indicación» y Consultar Ruta usen el paso real.
/// - Cada giro se anuncia dos veces según `TurnGuidancePolicy`: «En 40 metros, gira…» y
///   «Ahora, gira…». Ambos son P2 con `TurnDeadline`: el AudioArbiter los hace esperar a que
///   termine lo que suena, salvo que el giro no pueda esperar (spike SCRUM-309, SCRUM-44).
///   Cada anuncio vibra con el patrón de su lado (`HapticCue.turnLeft` / `.turnRight`).
/// - La última maniobra (la llegada) se anuncia una vez antes de llegar; «Llegaste a…» lo dice
///   Finalizar Ruta cuando `ArrivalMonitor` confirma la llegada.
/// - Avisa por audio si la señal de GPS se degrada o se pierde la red, y cuando vuelven. Nada
///   de esto toca la detección de obstáculos, que es local y no depende de la red ni del GPS.
@MainActor
final class TurnGuidanceMonitor: RouteTrackingObserving {
    private enum Signal { case good, weak }

    private let store: any ActiveRouteStoring
    private let arbiter: any AudioArbitrating
    private let haptics: any HapticFeedbackPlaying
    private let connectivity: any ConnectivityObserving
    private let policy: TurnGuidancePolicy
    private let estimator = RouteProgressEstimator()
    private let instructions = NavigationInstructionBuilder()
    private let now: () -> Date
    /// Cada cuánto se revisa que sigan llegando lecturas; nil no revisa solo (pruebas).
    private let watchdogInterval: TimeInterval?

    private(set) var isGuiding = false
    private var trackedRoute: (id: UUID, revision: Int)?
    /// Anuncios ya entregados en la revisión vigente: `turn-<paso>-<etapa>`.
    private var announced: Set<String> = []
    /// Contextos de los avisos previos que aún pueden estar en cola o sonando. Cada aviso
    /// previo va en un contexto propio del giro para cortarlo cuando ya toca «Ahora»: el
    /// árbitro atiende los P2 en orden de llegada y, si no, sonaría «En 25 metros…» cuando el
    /// giro ya está encima.
    private var prepareContexts: Set<String> = []
    private var signal = Signal.good
    private var consecutivePoorFixes = 0
    private var consecutiveGoodFixes = 0
    private var lastFixAt: Date?
    private var isOffline = false
    private var watchdog: Task<Void, Never>?

    init(
        store: any ActiveRouteStoring,
        arbiter: any AudioArbitrating,
        haptics: any HapticFeedbackPlaying,
        connectivity: any ConnectivityObserving,
        policy: TurnGuidancePolicy = TurnGuidancePolicy(),
        watchdogInterval: TimeInterval? = 5,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.arbiter = arbiter
        self.haptics = haptics
        self.connectivity = connectivity
        self.policy = policy
        self.watchdogInterval = watchdogInterval
        self.now = now
        connectivity.start { [weak self] in self?.connectionRestored() }
    }

    // MARK: RouteTrackingObserving

    func trackingDidStart() {
        guard !isGuiding else { return }
        isGuiding = true
        lastFixAt = now()
        signal = .good
        consecutivePoorFixes = 0
        consecutiveGoodFixes = 0
        isOffline = false
        startWatchdog()
    }

    func trackingDidStop() {
        guard isGuiding else { return }
        isGuiding = false
        watchdog?.cancel()
        watchdog = nil
        trackedRoute = nil
        announced = []
        cancelPrepareNotices()
    }

    func receive(_ fix: LocationFix) {
        guard isGuiding else { return }
        let time = now()
        lastFixAt = time
        // Sin ruta (terminó por otro camino): no hay nada que guiar.
        guard let route = try? store.load() else { return }
        track(route)
        checkConnectivity(route: route, now: time)
        guard policy.isPrecise(fix) else {
            registerPoorFix(route: route, now: time)
            return
        }
        registerGoodFix(route: route, now: time)
        guide(route, with: fix, now: time)
    }

    // MARK: Señal y red

    /// Revisa que sigan llegando lecturas y el estado de la red. La llama el temporizador;
    /// las pruebas la llaman directamente.
    func checkSignal() {
        guard isGuiding, let route = try? store.load() else { return }
        let time = now()
        checkConnectivity(route: route, now: time)
        guard signal == .good, let lastFixAt,
              time.timeIntervalSince(lastFixAt) >= policy.signalTimeoutSeconds else { return }
        setSignal(.weak, route: route, now: time)
    }

    /// Volvió la red (aviso del monitor de conectividad).
    func connectionRestored() {
        guard isGuiding, isOffline, let route = try? store.load() else { return }
        isOffline = false
        announce(TurnAnnouncements.online, key: "network-restored", route: route, now: now())
    }

    private func checkConnectivity(route: ActiveRoute, now time: Date) {
        let connected = connectivity.isConnected
        if !connected, !isOffline {
            isOffline = true
            announce(TurnAnnouncements.offline, key: "network-lost", route: route, now: time)
        } else if connected, isOffline {
            isOffline = false
            announce(TurnAnnouncements.online, key: "network-restored", route: route, now: time)
        }
    }

    private func registerPoorFix(route: ActiveRoute, now time: Date) {
        consecutiveGoodFixes = 0
        consecutivePoorFixes += 1
        if signal == .good, consecutivePoorFixes >= policy.weakSignalFixes {
            setSignal(.weak, route: route, now: time)
        }
    }

    private func registerGoodFix(route: ActiveRoute, now time: Date) {
        consecutivePoorFixes = 0
        guard signal == .weak else { return }
        consecutiveGoodFixes += 1
        if consecutiveGoodFixes >= policy.recoveredSignalFixes {
            setSignal(.good, route: route, now: time)
        }
    }

    private func setSignal(_ newSignal: Signal, route: ActiveRoute, now time: Date) {
        guard newSignal != signal else { return }
        signal = newSignal
        consecutivePoorFixes = 0
        consecutiveGoodFixes = 0
        switch newSignal {
        case .weak: announce(TurnAnnouncements.gpsWeak, key: "gps-weak", route: route, now: time)
        case .good: announce(TurnAnnouncements.gpsRecovered, key: "gps-recovered", route: route, now: time)
        }
    }

    // MARK: Giros

    private func guide(_ stored: ActiveRoute, with fix: LocationFix, now time: Date) {
        let position = fix.coordinate
        // Desviado: los giros de esta ruta ya no sirven; Recalcular Ruta se encarga.
        guard RouteProgressEstimator.distance(from: position, to: stored) <= policy.offRouteThresholdMeters else {
            return
        }
        let progress = estimator.progress(of: stored, at: position)
        guard !progress.isArriving, let step = progress.nextStep,
              let distance = progress.distanceToNextMeters else { return }
        let route = advance(stored, to: step.order)
        // Los avisos previos de giros ya pasados no deben sonar.
        cancelPrepareNotices(except: prepareContextID(for: route, step: step.order))

        let speed = policy.walkingSpeed(of: fix)
        guard let stage = policy.stage(distanceMeters: distance, speed: speed) else { return }

        if step.order == route.steps.last?.order {
            announceApproach(route, step: step, distance: distance, now: time)
            return
        }
        if let maneuver = step.maneuverCoordinate,
           maneuver.distance(to: route.origin.coordinate) <= policy.startRadiusMeters {
            // La primera indicación ya sonó con «Ruta lista».
            return
        }
        announceTurn(step, stage: stage, distance: distance, speed: speed, route: route, now: time)
    }

    /// Guarda el paso que viene en la copia local. Nunca retrocede: un salto del GPS no
    /// devuelve indicaciones ya hechas.
    private func advance(_ route: ActiveRoute, to order: Int) -> ActiveRoute {
        guard order > route.currentStep else { return route }
        var updated = route
        updated.currentStep = order
        do {
            try store.save(updated)
            return updated
        } catch {
            // Sin guardar, la guía sigue igual; Consultar Ruta usará el paso anterior.
            return route
        }
    }

    private func announceTurn(
        _ step: RouteStep, stage: TurnStage, distance: Double, speed: Double,
        route: ActiveRoute, now time: Date
    ) {
        let key = "turn-\(step.order)-\(stage.rawValue)"
        guard !announced.contains(key) else { return }
        announced.insert(key)
        // Si ya toca «Ahora», el aviso previo sobra.
        if stage == .now { announced.insert("turn-\(step.order)-\(TurnStage.prepare.rawValue)") }

        let maneuver = TurnManeuver(instruction: step.instruction)
        let deadline = TurnDeadline(
            distanceMeters: distance, speedMetersPerSecond: speed, geometry: maneuver.geometry, now: time
        )
        let text: String
        let expiresAt: Date
        let contextID: String
        switch stage {
        case .prepare:
            text = TurnAnnouncements.prepare(step, distanceMeters: distance)
            // Si todavía no sonó cuando llega el momento de «Ahora», ya no sirve.
            let untilNow = max(0, distance - policy.imminentDistance(speed: speed)) / speed
            expiresAt = time.addingTimeInterval(max(policy.announcementGraceSeconds, untilNow))
            contextID = prepareContextID(for: route, step: step.order)
            prepareContexts.insert(contextID)
        case .now:
            text = TurnAnnouncements.now(step, instructions: instructions)
            expiresAt = deadline.maneuverAt.addingTimeInterval(policy.announcementGraceSeconds)
            contextID = NavigationInstructionBuilder.contextID(for: route)
            // El aviso previo que aún espera (o suena) ya no sirve: se corta.
            let prepare = prepareContextID(for: route, step: step.order)
            if prepareContexts.remove(prepare) != nil { arbiter.cancel(contextIDs: [prepare]) }
        }
        arbiter.receive(AudioMessage(
            text: text,
            priority: .routeInformation,
            createdAt: time,
            expiresAt: expiresAt,
            contextID: contextID,
            deduplicationKey: key,
            turnDeadline: deadline
        ))
        if let cue = maneuver.direction.hapticCue { haptics.play(cue) }
    }

    private func announceApproach(_ route: ActiveRoute, step: RouteStep, distance: Double, now time: Date) {
        let key = "turn-\(step.order)-arrival"
        guard !announced.contains(key) else { return }
        announced.insert(key)
        announce(TurnAnnouncements.approaching(route, step: step, distanceMeters: distance), key: key, route: route, now: time)
    }

    // MARK: Apoyo

    /// Aviso P2 en el contexto de la revisión vigente: al finalizar o cambiar la ruta se corta
    /// con sus instrucciones. Uno igual que aún espera o suena no se duplica.
    private func announce(_ text: String, key: String, route: ActiveRoute, now time: Date) {
        arbiter.receive(AudioMessage(
            text: text,
            priority: .routeInformation,
            createdAt: time,
            contextID: NavigationInstructionBuilder.contextID(for: route),
            deduplicationKey: key
        ))
    }

    /// Ruta nueva, otro destino o recorrido recalculado: los giros se anuncian de nuevo y los
    /// avisos previos del recorrido anterior se cortan.
    private func track(_ route: ActiveRoute) {
        guard trackedRoute?.id != route.id || trackedRoute?.revision != route.revision else { return }
        trackedRoute = (route.id, route.revision)
        announced = []
        cancelPrepareNotices()
    }

    /// Contexto del aviso previo de un giro, dentro de la revisión de la ruta.
    private func prepareContextID(for route: ActiveRoute, step order: Int) -> String {
        "\(NavigationInstructionBuilder.contextID(for: route))-turn-\(order)"
    }

    private func cancelPrepareNotices(except kept: String? = nil) {
        let stale = prepareContexts.filter { $0 != kept }
        guard !stale.isEmpty else { return }
        prepareContexts.subtract(stale)
        arbiter.cancel(contextIDs: stale)
    }

    private func startWatchdog() {
        guard let interval = watchdogInterval, interval > 0 else { return }
        watchdog?.cancel()
        let nanoseconds = UInt64(interval * 1_000_000_000)
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                self?.checkSignal()
            }
        }
    }
}
