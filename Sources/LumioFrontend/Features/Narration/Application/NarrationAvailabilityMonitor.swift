import Foundation

/// SCRUM-41: Gestionar Disponibilidad de la Narración.
///
/// Mientras la pantalla de la ruta está abierta vigila la red (`ConnectivityObserving`) y el
/// estado del servicio (`GET /vision/status`, sin foto ni cupo):
///
/// - Con la narración disponible vuelve a mirar cada 30 s.
/// - Caída: reintenta con espera creciente (2, 4, 8… hasta 30 s, o lo que pida el backend) y
///   en cuanto vuelve la red.
/// - Cada resultado de una solicitud real (botón o automática) también cuenta: una descripción
///   que llega confirma que funciona; una falla de red o del servicio pide comprobar ya.
///
/// Avisa una sola vez al caer y una al volver, por el AudioArbiter como P2 `.routeInformation`
/// y con vibración (`HapticPreferencesService`), mediante el `FeedbackCatalog`. Si el usuario ya
/// oyó el motivo al pulsar el botón, la caída no se repite. Nada de esto toca la detección de
/// obstáculos, los giros ni la navegación: solo decide si se envían fotos.
@MainActor
final class NarrationAvailabilityMonitor: ObservableObject, NarrationAvailabilityObserving {
    static let healthyInterval: TimeInterval = 30
    static let initialRetryDelay: TimeInterval = 2
    static let maxRetryDelay: TimeInterval = 30

    @Published private(set) var availability: NarrationAvailability = .checking {
        didSet {
            if availability != oldValue { onChange?(availability) }
        }
    }
    var onChange: ((NarrationAvailability) -> Void)?
    private(set) var isRunning = false

    private let connectivity: any ConnectivityObserving
    private let status: any NarrationStatusChecking
    private let audio: (any AudioArbitrating)?
    private let haptics: (any HapticFeedbackPlaying)?
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    /// Cada comprobación nueva invalida las programadas antes: nunca hay dos cadenas de sondeo.
    private var generation = 0
    private var retryDelay = NarrationAvailabilityMonitor.initialRetryDelay
    /// El usuario sabe que la narración está caída (lo oyó): al volver se le avisa.
    private var outageKnown = false
    /// El usuario acaba de oír el motivo al pulsar el botón: la próxima caída no se anuncia.
    private var silenceNextOutage = false
    private var observingConnectivity = false

    init(
        connectivity: any ConnectivityObserving,
        status: any NarrationStatusChecking,
        audio: (any AudioArbitrating)?,
        haptics: (any HapticFeedbackPlaying)?,
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = {
            delay, work in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                work()
            }
        }
    ) {
        self.connectivity = connectivity
        self.status = status
        self.audio = audio
        self.haptics = haptics
        self.schedule = schedule
    }

    // MARK: Ciclo de vida

    /// Cada ruta parte de cero: se vuelve a comprobar y se anuncia la caída si la hay.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        outageKnown = false
        silenceNextOutage = false
        retryDelay = Self.initialRetryDelay
        availability = .checking
        if !observingConnectivity {
            observingConnectivity = true
            // El monitor de red guarda cada aviso: se registra una sola vez.
            connectivity.start { [weak self] in self?.recheck() }
        }
        recheck()
    }

    func stop() {
        isRunning = false
        generation += 1
    }

    func recheck() {
        guard isRunning else { return }
        Task { await refresh() }
    }

    // MARK: Resultados de las solicitudes

    func narrationSucceeded() {
        retryDelay = Self.initialRetryDelay
        silenceNextOutage = false
        // La descripción que acaba de entrar al árbitro ya dice que funciona: sin aviso.
        markAvailable(announce: false)
        guard isRunning else { return }
        generation += 1
        scheduleNext(after: Self.healthyInterval, token: generation)
    }

    func narrationFailed(_ reason: EnvironmentNarrationUnavailable, userNotified: Bool) {
        switch reason {
        case .offline, .serviceUnavailable, .timedOut, .notConfigured:
            silenceNextOutage = userNotified
            recheck()
        case .cameraInactive, .noUsableFrame, .sessionRequired, .rateLimited, .stale:
            // Cámara, sesión, límite de uso o respuesta vieja: la narración sigue disponible.
            break
        }
    }

    // MARK: Comprobación

    /// Una comprobación completa. Pública para probarla sin esperar al reloj.
    func refresh() async {
        guard isRunning else { return }
        generation += 1
        let token = generation
        guard connectivity.isConnected else {
            markUnavailable(.offline)
            scheduleNext(after: nextRetryDelay(), token: token)
            return
        }
        let result = await status.checkStatus()
        guard isRunning, token == generation else { return }
        switch result {
        case .available:
            retryDelay = Self.initialRetryDelay
            silenceNextOutage = false
            markAvailable(announce: true)
            scheduleNext(after: Self.healthyInterval, token: token)
        case .unreachable:
            markUnavailable(.offline)
            scheduleNext(after: nextRetryDelay(), token: token)
        case .unavailable(let retryAfter):
            markUnavailable(.serviceDown)
            let backoff = nextRetryDelay()
            let requested = min(retryAfter ?? 0, Self.maxRetryDelay)
            scheduleNext(after: max(backoff, requested), token: token)
        }
    }

    private func nextRetryDelay() -> TimeInterval {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
        return delay
    }

    private func scheduleNext(after delay: TimeInterval, token: Int) {
        schedule(delay) { [weak self] in
            guard let self, self.isRunning, token == self.generation else { return }
            Task { await self.refresh() }
        }
    }

    // MARK: Transiciones

    private func markUnavailable(_ outage: NarrationOutage) {
        availability = .unavailable(outage)
        if silenceNextOutage {
            silenceNextOutage = false
            outageKnown = true
            return
        }
        guard !outageKnown else { return }
        outageKnown = true
        FeedbackCatalog.emit(.narrationUnavailable(outage), audio: audio, haptics: haptics)
    }

    private func markAvailable(announce: Bool) {
        availability = .available
        guard outageKnown else { return }
        outageKnown = false
        // Un «no disponible» que aún no sonó ya no es cierto.
        audio?.cancel(contextIDs: [EnvironmentNarrationService.statusContextID])
        guard announce else { return }
        FeedbackCatalog.emit(.narrationAvailable, audio: audio, haptics: haptics)
    }
}
