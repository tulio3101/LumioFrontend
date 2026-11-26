import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

// SCRUM-41: Gestionar Disponibilidad de la Narración (monitor, avisos P2 con vibración,
// política durante la caída, reanudación y GET /vision/status).

// MARK: Dobles

private final class FakeStatus: NarrationStatusChecking, @unchecked Sendable {
    var result: NarrationServiceStatus = .available
    private(set) var checks = 0

    func checkStatus() async -> NarrationServiceStatus {
        checks += 1
        return result
    }
}

/// Guarda lo programado; la prueba decide cuándo «pasa el tiempo».
private final class ManualScheduler: @unchecked Sendable {
    private(set) var delays: [TimeInterval] = []
    private var pending: [@MainActor () -> Void] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        delays.append(delay)
        pending.append(work)
    }

    /// Ejecuta todo lo programado hasta ahora.
    @MainActor
    func fire() {
        let works = pending
        pending = []
        for work in works { work() }
    }
}

@MainActor
private struct MonitorHarness {
    let monitor: NarrationAvailabilityMonitor
    let status: FakeStatus
    let connectivity: FakeConnectivity
    let arbiter: SpyArbiter
    let haptics: SpyHaptics
    let scheduler: ManualScheduler

    var spoken: [String] { arbiter.received.map(\.text) }
}

@MainActor
private func makeMonitor(status result: NarrationServiceStatus = .available) -> MonitorHarness {
    let status = FakeStatus()
    status.result = result
    let connectivity = FakeConnectivity()
    let arbiter = SpyArbiter()
    let haptics = SpyHaptics()
    let scheduler = ManualScheduler()
    let monitor = NarrationAvailabilityMonitor(
        connectivity: connectivity, status: status, audio: arbiter, haptics: haptics,
        schedule: { delay, work in scheduler.schedule(delay, work) }
    )
    return MonitorHarness(
        monitor: monitor, status: status, connectivity: connectivity, arbiter: arbiter,
        haptics: haptics, scheduler: scheduler
    )
}

/// Deja correr las tareas que lanzó el monitor (`recheck`, temporizadores).
@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private final class FakeAvailability: NarrationAvailabilityObserving {
    private(set) var availability: NarrationAvailability = .checking
    var onChange: ((NarrationAvailability) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var rechecks = 0
    private(set) var successes = 0
    private(set) var failures: [EnvironmentNarrationUnavailable] = []
    private(set) var notified: [Bool] = []

    func set(_ state: NarrationAvailability) {
        availability = state
        onChange?(state)
    }

    func start() { starts += 1 }
    func stop() { stops += 1 }
    func recheck() { rechecks += 1 }
    func narrationSucceeded() { successes += 1 }
    func narrationFailed(_ reason: EnvironmentNarrationUnavailable, userNotified: Bool) {
        failures.append(reason)
        notified.append(userNotified)
    }
}

private final class StepClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// La «foto» es un byte con el número de la escena.
private final class SceneCapturer: NarrationFrameCapturing {
    var scene: UInt8 = 1
    private(set) var calls = 0
    private let clock: StepClock

    init(clock: StepClock) { self.clock = clock }

    func captureNarrationFrame() async -> NarrationCapture {
        calls += 1
        return .frame(NarrationFrame(jpeg: Data([scene]), capturedAt: clock.now))
    }
}

private struct ByteSignatures: SceneSignatureProviding {
    func signature(for jpeg: Data) -> SceneSignature? {
        switch jpeg.first {
        case 1: return SceneSignature([1, 0])
        case 2: return SceneSignature([0, 1])
        default: return nil
        }
    }
}

private final class FakeDescriber: EnvironmentDescribing, @unchecked Sendable {
    var error: Error?
    private(set) var requests: [NarrationTrigger] = []

    func describe(
        _ frame: NarrationFrame, trigger: NarrationTrigger, consentVersion: String
    ) async throws -> String {
        requests.append(trigger)
        if let error { throw error }
        return "Delante hay una puerta."
    }
}

@MainActor
private final class GrantedConsent: NarrationConsentGating {
    var consentVersionForUpload: String? { NarrationConsentPolicy.currentVersion }
    func requireConsentBeforeNarration() -> Bool { true }
}

@MainActor
private struct ServiceHarness {
    let service: EnvironmentNarrationService
    let scheduler: AutoNarrationScheduler
    let availability: FakeAvailability
    let capturer: SceneCapturer
    let describer: FakeDescriber
    let connectivity: FakeConnectivity
    let arbiter: SpyArbiter
    let clock: StepClock
}

@MainActor
private func makeService() -> ServiceHarness {
    let clock = StepClock()
    let capturer = SceneCapturer(clock: clock)
    let describer = FakeDescriber()
    let consent = GrantedConsent()
    let connectivity = FakeConnectivity()
    let arbiter = SpyArbiter()
    let never: (TimeInterval) async throws -> Void = { _ in
        try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
    }
    let service = EnvironmentNarrationService(
        capturer: capturer, describer: describer, consent: consent,
        connectivity: connectivity, arbiter: arbiter, sleep: never, now: { clock.now }
    )
    let scheduler = AutoNarrationScheduler(
        service: service, capturer: capturer, signatures: ByteSignatures(), consent: consent,
        connectivity: connectivity, channel: nil, isLowPowerMode: { false },
        sleep: never, now: { clock.now }
    )
    service.autoUpdates = scheduler
    let availability = FakeAvailability()
    service.availability = availability
    return ServiceHarness(
        service: service, scheduler: scheduler, availability: availability, capturer: capturer,
        describer: describer, connectivity: connectivity, arbiter: arbiter, clock: clock
    )
}

// MARK: Identificar la disponibilidad (criterio 1)

@Test @MainActor func availableServiceIsIdentifiedWithoutAnnouncing() async {
    let h = makeMonitor()

    h.monitor.start()
    await settle()

    #expect(h.monitor.availability == .available)
    #expect(h.status.checks == 1)
    // Que esté disponible es lo normal: no se dice nada.
    #expect(h.arbiter.received.isEmpty)
    #expect(h.haptics.cues.isEmpty)
    // Mientras está disponible vuelve a mirar cada 30 s.
    #expect(h.scheduler.delays == [NarrationAvailabilityMonitor.healthyInterval])
}

@Test @MainActor func checkingDoesNotBlockTheFirstRequest() {
    #expect(!NarrationAvailability.checking.isUnavailable)
    #expect(!NarrationAvailability.available.isUnavailable)
    #expect(NarrationAvailability.unavailable(.offline).isUnavailable)
}

// MARK: Detectar la caída y avisar (criterios 2 y 3)

@Test @MainActor func serviceDownIsAnnouncedOnceAsP2WithVibration() async {
    let h = makeMonitor(status: .unavailable(retryAfter: nil))

    h.monitor.start()
    await settle()
    await h.monitor.refresh()

    #expect(h.monitor.availability == .unavailable(.serviceDown))
    #expect(h.arbiter.received.count == 1)
    let message = h.arbiter.received[0]
    #expect(message.text == EnvironmentNarrationMessages.outage(.serviceDown))
    #expect(message.text.contains("La detección de obstáculos sigue activa"))
    #expect(message.priority == .routeInformation)
    #expect(message.contextID == EnvironmentNarrationService.statusContextID)
    #expect(h.haptics.cues == [.narrationUnavailable])
}

@Test @MainActor func lostConnectivityIsDetectedWithoutCallingTheServer() async {
    let h = makeMonitor()
    h.connectivity.isConnected = false

    h.monitor.start()
    await settle()

    #expect(h.monitor.availability == .unavailable(.offline))
    #expect(h.status.checks == 0)
    #expect(h.spoken == [EnvironmentNarrationMessages.outage(.offline)])
}

@Test @MainActor func unreachableServerCountsAsOffline() async {
    let h = makeMonitor(status: .unreachable)

    h.monitor.start()
    await settle()

    #expect(h.monitor.availability == .unavailable(.offline))
}

@Test @MainActor func retriesBackOffUpToTheCapAndHonorRetryAfter() async {
    let h = makeMonitor(status: .unavailable(retryAfter: nil))
    h.monitor.start()
    await settle()

    for _ in 0..<5 {
        h.scheduler.fire()
        await settle()
    }

    #expect(h.scheduler.delays == [2, 4, 8, 16, 30, 30])

    h.status.result = .unavailable(retryAfter: 25)
    h.monitor.stop()
    h.monitor.start()
    await settle()
    // Reinicia la espera (2 s), pero el backend pidió 25.
    #expect(h.scheduler.delays.last == 25)
}

@Test @MainActor func lossDuringTheRouteIsAnnouncedWhenFound() async {
    let h = makeMonitor()
    h.monitor.start()
    await settle()

    h.status.result = .unavailable(retryAfter: 30)
    h.scheduler.fire()
    await settle()

    #expect(h.monitor.availability == .unavailable(.serviceDown))
    #expect(h.haptics.cues == [.narrationUnavailable])
}

// MARK: Reanudar (criterio 5)

@Test @MainActor func recoveryIsAnnouncedAndCancelsAPendingOutageNotice() async {
    let h = makeMonitor(status: .unavailable(retryAfter: nil))
    h.monitor.start()
    await settle()

    h.status.result = .available
    h.scheduler.fire()
    await settle()

    #expect(h.monitor.availability == .available)
    #expect(h.spoken == [
        EnvironmentNarrationMessages.outage(.serviceDown), EnvironmentNarrationMessages.available,
    ])
    #expect(h.arbiter.received.last?.priority == .routeInformation)
    #expect(h.haptics.cues == [.narrationUnavailable, .narrationAvailable])
    #expect(h.arbiter.cancelledContexts.contains([EnvironmentNarrationService.statusContextID]))
}

@Test @MainActor func reconnectingChecksAtOnce() async {
    let h = makeMonitor()
    h.connectivity.isConnected = false
    h.monitor.start()
    await settle()

    h.connectivity.isConnected = true
    for handler in h.connectivity.handlers { handler() }
    await settle()

    #expect(h.monitor.availability == .available)
    #expect(h.spoken.last == EnvironmentNarrationMessages.available)
}

@Test @MainActor func connectivityIsObservedOnceAcrossRoutes() async {
    let h = makeMonitor()

    h.monitor.start()
    h.monitor.stop()
    h.monitor.start()
    await settle()

    #expect(h.connectivity.handlers.count == 1)
}

@Test @MainActor func stoppedMonitorIgnoresTimersAndReconnects() async {
    let h = makeMonitor()
    h.monitor.start()
    await settle()
    let checks = h.status.checks

    h.monitor.stop()
    h.scheduler.fire()
    for handler in h.connectivity.handlers { handler() }
    await settle()

    #expect(h.status.checks == checks)
    #expect(!h.monitor.isRunning)
}

@Test @MainActor func aDescriptionConfirmsRecoveryWithoutAnExtraNotice() async {
    let h = makeMonitor(status: .unavailable(retryAfter: nil))
    h.monitor.start()
    await settle()

    h.monitor.narrationSucceeded()

    #expect(h.monitor.availability == .available)
    // La descripción que acaba de sonar ya lo dice.
    #expect(h.spoken == [EnvironmentNarrationMessages.outage(.serviceDown)])
}

// MARK: Resultado de las solicitudes

@Test @MainActor func aFailureTheUserAlreadyHeardIsNotAnnouncedAgain() async {
    let h = makeMonitor()
    h.monitor.start()
    await settle()

    h.status.result = .unavailable(retryAfter: nil)
    h.monitor.narrationFailed(.serviceUnavailable, userNotified: true)
    await settle()

    #expect(h.monitor.availability == .unavailable(.serviceDown))
    #expect(h.arbiter.received.isEmpty)

    // Pero sí se avisa cuando vuelve.
    h.status.result = .available
    h.scheduler.fire()
    await settle()
    #expect(h.spoken == [EnvironmentNarrationMessages.available])
}

@Test @MainActor func failuresThatAreNotAnOutageDoNotCheck() async {
    let h = makeMonitor()
    h.monitor.start()
    await settle()
    let checks = h.status.checks

    for reason in [EnvironmentNarrationUnavailable.rateLimited, .stale, .cameraInactive, .noUsableFrame, .sessionRequired] {
        h.monitor.narrationFailed(reason, userNotified: false)
    }
    await settle()

    #expect(h.status.checks == checks)
    #expect(h.monitor.availability == .available)
}

@Test @MainActor func anAutomaticFailureConfirmedByTheServerIsAnnounced() async {
    let h = makeMonitor()
    h.monitor.start()
    await settle()

    h.status.result = .unavailable(retryAfter: 30)
    h.monitor.narrationFailed(.timedOut, userNotified: false)
    await settle()

    #expect(h.spoken == [EnvironmentNarrationMessages.outage(.serviceDown)])
}

@Test @MainActor func aSingleSlowAnswerDoesNotMarkTheNarrationDown() async {
    let h = makeMonitor()
    h.monitor.start()
    await settle()

    h.monitor.narrationFailed(.timedOut, userNotified: false)
    await settle()

    #expect(h.monitor.availability == .available)
    #expect(h.arbiter.received.isEmpty)
}

// MARK: Política durante la caída (criterio 6) y seguridad intacta (criterio 4)

@Test @MainActor func buttonDuringAnOutageAnswersAtOnceAndRechecks() async {
    let h = makeService()
    h.availability.set(.unavailable(.serviceDown))

    let outcome = await h.service.describeEnvironment(trigger: .gesture)

    #expect(outcome == .unavailable(.serviceUnavailable))
    // No se toma ni se envía la foto, y no se encola nada.
    #expect(h.capturer.calls == 0)
    #expect(h.describer.requests.isEmpty)
    #expect(h.availability.rechecks == 1)
    let message = h.arbiter.received.last
    #expect(message?.text == EnvironmentNarrationMessages.stillUnavailable(.serviceDown))
    #expect(message?.priority == .routeInformation)
    #expect(message?.contextID == EnvironmentNarrationService.statusContextID)
    #expect(h.service.isDescribing == false)
}

@Test @MainActor func automaticRequestsDuringAnOutageStaySilent() async {
    let h = makeService()
    h.availability.set(.unavailable(.offline))

    let outcome = await h.service.describeEnvironment(trigger: .auto)

    #expect(outcome == .unavailable(.offline))
    #expect(h.capturer.calls == 0)
    #expect(h.arbiter.received.isEmpty)
}

@Test @MainActor func schedulerTakesNoPhotoWhileTheNarrationIsDown() async {
    let h = makeService()
    h.scheduler.start()
    defer { h.scheduler.stop() }
    h.availability.set(.unavailable(.serviceDown))

    #expect(await h.scheduler.tick() == .skipped(.narrationUnavailable))
    #expect(h.capturer.calls == 0)
}

@Test @MainActor func requestsReportTheirResultToTheMonitor() async {
    let h = makeService()

    #expect(await h.service.describeEnvironment(trigger: .gesture) == .described("Delante hay una puerta."))
    #expect(h.availability.successes == 1)

    h.describer.error = HTTPClientError.statusCode(503)
    // SCRUM-39: pedir otra vez enseguida repite la descripción sin red; se espera a que pase
    // esa ventana para que la segunda solicitud llegue al backend.
    h.clock.advance(NarrationRepeatPolicy().replayWindow)
    _ = await h.service.describeEnvironment(trigger: .gesture)
    h.connectivity.isConnected = false
    _ = await h.service.describeEnvironment(trigger: .auto)

    #expect(h.availability.failures == [.serviceUnavailable, .offline])
    #expect(h.availability.notified == [true, false])
}

@Test @MainActor func recoveryResumesAutomaticUpdatesWithoutWaitingTheBackoff() async {
    let h = makeService()
    h.scheduler.start()
    defer { h.scheduler.stop() }
    #expect(await h.scheduler.tick() == .baselineSet)

    // Una automática falla: el planificador hace una pausa de 30 s.
    h.clock.advance(10)
    h.capturer.scene = 2
    h.describer.error = HTTPClientError.statusCode(503)
    #expect(await h.scheduler.tick() == .requested(.unavailable(.serviceUnavailable)))
    h.clock.advance(11)
    #expect(await h.scheduler.tick() == .skipped(.backingOff))

    // Se cae y vuelve: la pausa se olvida.
    h.availability.set(.unavailable(.serviceDown))
    #expect(h.service.narrationAvailability == .unavailable(.serviceDown))
    h.availability.set(.available)
    h.describer.error = nil

    #expect(await h.scheduler.tick() == .requested(.described("Delante hay una puerta.")))
}

@Test @MainActor func routeScreenStartsAndStopsTheMonitor() {
    let h = makeService()

    h.service.startAutoUpdates()
    h.service.stopAutoUpdates()

    #expect(h.availability.starts == 1)
    #expect(h.availability.stops == 1)
}

@Test func outageMessagesSayThatObstacleDetectionContinues() {
    for outage in [NarrationOutage.offline, .serviceDown] {
        #expect(EnvironmentNarrationMessages.outage(outage).contains("La detección de obstáculos sigue activa"))
        #expect(EnvironmentNarrationMessages.stillUnavailable(outage).contains("La detección de obstáculos sigue activa"))
    }
}

@Test func catalogItemsAreP2WithTheirOwnVibration() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let down = FeedbackCatalog.item(for: .narrationUnavailable(.offline), now: now)
    let back = FeedbackCatalog.item(for: .narrationAvailable, now: now)

    #expect(down.message.priority == .routeInformation)
    #expect(back.message.priority == .routeInformation)
    #expect(down.message.contextID == NarrationAudio.statusContextID)
    #expect(down.message.contextID != NarrationAudio.contextID)
    #expect(down.haptic == .narrationUnavailable)
    #expect(back.haptic == .narrationAvailable)
    #expect(HapticCue.configurable.contains(.narrationUnavailable))
    #expect(HapticCue.configurable.contains(.narrationAvailable))
}

// MARK: GET /vision/status

@Test func statusServiceAsksVisionStatusWithoutSession() async throws {
    let client = FakeHTTPClient(response: .success(Data(#"{"available":true,"reason":"available","retry_after_seconds":null}"#.utf8)))
    let remote = RemoteNarrationStatusService(client: client, baseURL: URL(string: "https://api.example.com")!)

    #expect(await remote.checkStatus() == .available)
    let request = try #require(client.requests.first)
    #expect(request.url?.absoluteString == "https://api.example.com/vision/status")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.timeoutInterval == 4)
}

@Test func statusServiceReadsDegradedWithRetryAfter() async {
    let client = FakeHTTPClient(response: .success(Data(#"{"available":false,"reason":"degraded","retry_after_seconds":12}"#.utf8)))
    let remote = RemoteNarrationStatusService(client: client, baseURL: URL(string: "https://api.example.com")!)

    #expect(await remote.checkStatus() == .unavailable(retryAfter: 12))
}

@Test func statusServiceMapsFailures() async {
    let base = URL(string: "https://api.example.com")!
    let offline = FakeHTTPClient(response: .failure(URLError(.notConnectedToInternet)))
    let serverError = FakeHTTPClient(response: .failure(HTTPClientError.statusCode(503)))
    let oldBackend = FakeHTTPClient(response: .failure(HTTPClientError.statusCode(404)))
    let garbage = FakeHTTPClient(response: .success(Data("<html>".utf8)))

    #expect(await RemoteNarrationStatusService(client: offline, baseURL: base).checkStatus() == .unreachable)
    #expect(await RemoteNarrationStatusService(client: serverError, baseURL: base).checkStatus() == .unavailable(retryAfter: nil))
    // Un backend sin /vision/status respondió: se intenta la narración.
    #expect(await RemoteNarrationStatusService(client: oldBackend, baseURL: base).checkStatus() == .available)
    #expect(await RemoteNarrationStatusService(client: garbage, baseURL: base).checkStatus() == .unavailable(retryAfter: nil))
    #expect(await RemoteNarrationStatusService(client: offline, baseURL: nil).checkStatus() == .unavailable(retryAfter: nil))
}
