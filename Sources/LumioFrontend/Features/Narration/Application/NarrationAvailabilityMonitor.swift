import Foundation

/// SCRUM-41: vigila red + health check al backend con backoff. Avisa una sola vez al caer y
/// al volver (FeedbackCatalog, P3). Las solicitudes durante la caída se descartan con aviso.
/// No toca la detección ni la navegación.
@MainActor
final class NarrationAvailabilityMonitor: ObservableObject, NarrationAvailabilityObserving {
    @Published private(set) var availability: NarrationAvailability = .checking

    private let connectivity: any ConnectivityObserving
    private let health: any EndpointHealthChecking
    private let audio: (any AudioArbitrating)?
    private let haptics: (any HapticFeedbackPlaying)?
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var generation = 0
    private var nextDelay: TimeInterval = 2
    private let maxDelay: TimeInterval = 30
    private let healthyInterval: TimeInterval = 30
    private var announcedOutage = false
    private var started = false

    init(
        connectivity: any ConnectivityObserving,
        health: any EndpointHealthChecking,
        audio: (any AudioArbitrating)? = nil,
        haptics: (any HapticFeedbackPlaying)? = nil,
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = {
            delay, work in
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await work()
            }
        }
    ) {
        self.connectivity = connectivity
        self.health = health
        self.audio = audio
        self.haptics = haptics
        self.schedule = schedule
    }

    func start() {
        guard !started else { return }
        started = true
        connectivity.start { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func allowRequest() -> Bool {
        guard availability == .available else {
            FeedbackCatalog.emit(.narrationRequestDropped, audio: audio, haptics: haptics)
            return false
        }
        return true
    }

    /// Lo llaman las pruebas (y el reconectado) para reevaluar sin esperar al temporizador.
    func refresh() async {
        generation += 1
        let token = generation
        if !connectivity.isConnected {
            markUnavailable()
            return
        }
        if availability != .available {
            availability = .checking
        }
        let reachable = await health.isReachable()
        guard token == generation else { return }
        if reachable {
            nextDelay = 2
            markAvailable()
            schedule(healthyInterval) { [weak self] in
                Task { await self?.refresh() }
            }
        } else {
            markUnavailable()
            let delay = nextDelay
            nextDelay = min(nextDelay * 2, maxDelay)
            schedule(delay) { [weak self] in
                Task { await self?.refresh() }
            }
        }
    }

    private func markUnavailable() {
        availability = .unavailable
        guard !announcedOutage else { return }
        announcedOutage = true
        FeedbackCatalog.emit(.narrationUnavailable, audio: audio, haptics: haptics)
    }

    private func markAvailable() {
        let wasDown = announcedOutage
        availability = .available
        guard wasDown else { return }
        announcedOutage = false
        FeedbackCatalog.emit(.narrationAvailable, audio: audio, haptics: haptics)
    }
}
