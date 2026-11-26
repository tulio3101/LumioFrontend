import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

// SCRUM-40: Actualizar Narración ante Cambios de Entorno (huella de escena, ritmo, canal libre,
// fallas silenciosas y tope de la ruta).

// MARK: Dobles

private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// La «foto» es un solo byte: el número de la escena. La captura lleva la hora del reloj.
private final class SceneCapturer: NarrationFrameCapturing {
    var scene: UInt8 = 1
    var unusable = false
    private(set) var calls = 0
    private let clock: TestClock

    init(clock: TestClock) { self.clock = clock }

    func captureNarrationFrame() async -> NarrationCapture {
        calls += 1
        if unusable { return .noUsableFrame }
        return .frame(NarrationFrame(jpeg: Data([scene]), capturedAt: clock.now))
    }
}

/// Escena 1 y 2 son muy distintas; la 3 es casi igual a la 1.
private struct FakeSignatures: SceneSignatureProviding {
    private let table: [UInt8: [Float]] = [
        1: [1, 0],
        2: [0, 1],
        3: [1, 0.05],
    ]

    func signature(for jpeg: Data) -> SceneSignature? {
        guard let id = jpeg.first, let vector = table[id] else { return nil }
        return SceneSignature(vector)
    }
}

private final class FakeDescriber: EnvironmentDescribing, @unchecked Sendable {
    var text = "Delante hay un cruce peatonal con semáforo."
    var error: Error?
    /// Se ejecuta mientras «viaja» la solicitud (p. ej., para dejar pasar el tiempo).
    var onDescribe: (() -> Void)?
    private(set) var requests: [(frame: NarrationFrame, trigger: NarrationTrigger)] = []

    func describe(
        _ frame: NarrationFrame, trigger: NarrationTrigger, consentVersion: String
    ) async throws -> String {
        requests.append((frame, trigger))
        onDescribe?()
        if let error { throw error }
        return text
    }
}

@MainActor
private final class FakeConsent: NarrationConsentGating {
    var granted = true
    private(set) var asked = 0
    var consentVersionForUpload: String? { granted ? NarrationConsentPolicy.currentVersion : nil }
    func requireConsentBeforeNarration() -> Bool {
        asked += 1
        return granted
    }
}

@MainActor
private final class RecordingArbiter: AudioArbitrating {
    private(set) var received: [AudioMessage] = []
    func receive(_ message: AudioMessage) { received.append(message) }
    func processNext() {}
    func playbackFinished(token: PlaybackToken) {}
    func discardIrrelevant() {}
    func resetSession() {}
    func updateContext(_ context: AudioDecisionContext) {}
    func cancel(contextIDs: Set<String>) {}

    var narrations: [AudioMessage] { received.filter { $0.contextID == NarrationAudio.contextID } }
}

@MainActor
private final class FakeChannel: AudioChannelObserving {
    var isChannelFree = true
}

@MainActor
private struct Harness {
    let scheduler: AutoNarrationScheduler
    let service: EnvironmentNarrationService
    let capturer: SceneCapturer
    let describer: FakeDescriber
    let consent: FakeConsent
    let connectivity: FakeConnectivity
    let arbiter: RecordingArbiter
    let channel: FakeChannel
    let clock: TestClock
    let lowPower: LowPowerFlag
}

private final class LowPowerFlag { var enabled = false }

@MainActor
private func makeHarness(
    configuration: AutoNarrationConfiguration = AutoNarrationConfiguration()
) -> Harness {
    let clock = TestClock()
    let capturer = SceneCapturer(clock: clock)
    let describer = FakeDescriber()
    let consent = FakeConsent()
    let connectivity = FakeConnectivity()
    let arbiter = RecordingArbiter()
    let channel = FakeChannel()
    let lowPower = LowPowerFlag()
    let never: (TimeInterval) async throws -> Void = { _ in
        try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
    }
    let service = EnvironmentNarrationService(
        capturer: capturer, describer: describer, consent: consent,
        connectivity: connectivity, arbiter: arbiter, sleep: never, now: { clock.now }
    )
    let scheduler = AutoNarrationScheduler(
        service: service, capturer: capturer, signatures: FakeSignatures(), consent: consent,
        connectivity: connectivity, channel: channel, configuration: configuration,
        isLowPowerMode: { lowPower.enabled }, sleep: never, now: { clock.now }
    )
    service.autoUpdates = scheduler
    scheduler.start()
    return Harness(
        scheduler: scheduler, service: service, capturer: capturer, describer: describer,
        consent: consent, connectivity: connectivity, arbiter: arbiter, channel: channel,
        clock: clock, lowPower: lowPower
    )
}

// MARK: Huella de escena

@Test func sceneSignatureIsNormalizedAndComparable() {
    let a = SceneSignature([3, 4])
    let b = SceneSignature([6, 8])
    let c = SceneSignature([0, 5])

    #expect(a == b)
    #expect(a?.distance(to: b!) == 0)
    #expect((a?.distance(to: c!) ?? 0) > 0.5)
}

@Test func emptyOrZeroSignaturesAreRejected() {
    #expect(SceneSignature([]) == nil)
    #expect(SceneSignature([0, 0, 0]) == nil)
    #expect(SceneSignature([1, 2])?.distance(to: SceneSignature([1, 2, 3])!) == nil)
}

@Test func backoffDoublesUpToTheCap() {
    let configuration = AutoNarrationConfiguration()

    #expect(configuration.backoff(afterFailures: 0) == 0)
    #expect(configuration.backoff(afterFailures: 1) == 30)
    #expect(configuration.backoff(afterFailures: 2) == 60)
    #expect(configuration.backoff(afterFailures: 3) == 120)
    #expect(configuration.backoff(afterFailures: 9) == 120)
}

// MARK: Escena sin cambios o con cambios (criterios 2 y 3)

@Test @MainActor func firstSceneOnlyBecomesTheReference() async {
    let h = makeHarness()
    defer { h.scheduler.stop() }

    #expect(await h.scheduler.tick() == .baselineSet)
    #expect(h.describer.requests.isEmpty)
    #expect(h.arbiter.received.isEmpty)
}

@Test @MainActor func anUnchangedSceneSendsNothing() async {
    let h = makeHarness()
    defer { h.scheduler.stop() }
    await h.scheduler.tick()

    h.clock.advance(20)
    h.capturer.scene = 3
    #expect(await h.scheduler.tick() == .skipped(.sameScene))
    #expect(h.describer.requests.isEmpty)
}

@Test @MainActor func aSignificantChangeAsksForANewNarrationAsAuto() async {
    let h = makeHarness()
    defer { h.scheduler.stop() }
    await h.scheduler.tick()

    h.clock.advance(10)
    h.capturer.scene = 2
    let decision = await h.scheduler.tick()

    #expect(decision == .requested(.described("Delante hay un cruce peatonal con semáforo.")))
    #expect(h.describer.requests.count == 1)
    #expect(h.describer.requests.first?.trigger == .auto)
    // La misma foto que se comparó es la que se envió: no hay una segunda captura.
    #expect(h.describer.requests.first?.frame.jpeg == Data([2]))
    #expect(h.capturer.calls == 2)
    #expect(h.arbiter.narrations.first?.priority == .environmentInformation)
}

@Test @MainActor func theNarratedSceneBecomesTheNewReference() async {
    let h = makeHarness()
    defer { h.scheduler.stop() }
    await h.scheduler.tick()
    h.clock.advance(10)
    h.capturer.scene = 2
    await h.scheduler.tick()

    h.clock.advance(10)
    #expect(await h.scheduler.tick() == .skipped(.sameScene))
    #expect(h.describer.requests.count == 1)
}

@Test @MainActor func aDescriptionRequestedWithTheButtonBecomesTheReference() async {
    let h = makeHarness()
    defer { h.scheduler.stop() }
    await h.scheduler.tick()

    h.capturer.scene = 2
    await h.service.describeEnvironment()
    h.clock.advance(10)

    // La escena 2 ya se narró con el botón: no se vuelve a pedir.
    #expect(await h.scheduler.tick() == .skipped(.sameScene))
    #expect(h.describer.requests.map { $0.trigger } == [.gesture])
}

// MARK: Frecuencia (criterio 1)

@Test @MainActor func narrationsAreAtLeastTenSecondsApart() async {
    let h = makeHarness()
    defer { h.scheduler.stop() }
    await h.scheduler.tick()
    h.clock.advance(10)
    h.capturer.scene = 2
    await h.scheduler.tick()

    h.clock.advance(5)
    h.capturer.scene = 1
    #expect(await h.scheduler.tick() == .skipped(.tooSoon))
    // Antes del mínimo ni siquiera se toma la foto.
    #expect(h.capturer.calls == 2)

    h.clock.advance(5)
    if case .requested = await h.scheduler.tick() {} else { Issue.record("debía pedir otra") }
    #expect(h.describer.requests.count == 2)
}

@Test @MainActor func aButtonDescriptionAlsoCountsTowardTheMinimum() async {
    let h = makeHarness()
    defer { h.scheduler.stop() }
    await h.scheduler.tick()
    await h.service.describeEnvironment()

    h.clock.advance(3)
    h.capturer.scene = 2
    #expect(await h.scheduler.tick() == .skipped(.tooSoon))
}

@Test @MainActor func lowPowerModeDoublesTheMinimum() async {
    let h = makeHarness()
    defer { h.scheduler.stop() }
    await h.scheduler.tick()
    h.clock.advance(10)
    h.capturer.scene = 2
    await h.scheduler.tick()
    h.lowPower.enabled = true

    h.clock.advance(15)
    h.capturer.scene = 1
    #expect(await h.scheduler.tick() == .skipped(.tooSoon))
    h.clock.advance(5)
    if case .requested = await h.scheduler.tick() {} else { Issue.record("debía pedir otra") }
}

@Test @MainActor func theRouteHasARequestBudget() async {
    var configuration = AutoNarrationConfiguration()
    configuration.maxRequestsPerRoute = 1
    let h = makeHarness(configuration: configuration)
    defer { h.scheduler.stop() }
    await h.scheduler.tick()
    h.clock.advance(10)
    h.capturer.scene = 2
    await h.scheduler.tick()

    h.clock.advance(10)
    h.capturer.scene = 1
    #expect(await h.scheduler.tick() == .skipped(.routeBudgetExhausted))
    #expect(h.describer.requests.count == 1)
}

// MARK: Canal de audio y prioridad (criterios 4 y 5)

@Test @MainActor func aBusyChannelPostponesTheRequestWithoutTakingAPhoto() async {
    let h = makeHarness()
    defer { h.scheduler.stop() }
    await h.scheduler.tick()
    h.clock.advance(10)
    h.capturer.scene = 2
    h.channel.isChannelFree = false
    let calls = h.capturer.calls

    #expect(await h.scheduler.tick() == .skipped(.channelBusy))
    #expect(h.capturer.calls == calls)
    #expect(h.describer.requests.isEmpty)

    h.channel.isChannelFree = true
    if case .requested = await h.scheduler.tick() {} else { Issue.record("debía pedir al liberarse") }
}

@Test @MainActor func aStaleResponseIsNeverNarrated() async {
    let h = makeHarness()
    defer { h.scheduler.stop() }
    await h.scheduler.tick()
    h.clock.advance(10)
    h.capturer.scene = 2
    // La respuesta llega 5 s después de la foto: ya no describe lo que hay delante.
    h.describer.onDescribe = { h.clock.advance(5) }

    let decision = await h.scheduler.tick()

    #expect(decision == .requested(.unavailable(.stale)))
    #expect(h.arbiter.received.isEmpty)
}

// MARK: Sin red y sin consentimiento (criterio 6)

@Test @MainActor func withoutConnectionNothingIsAttemptedAndSafetyIsUntouched() async {
    let h = makeHarness()
    defer { h.scheduler.stop() }
    await h.scheduler.tick()
    h.clock.advance(10)
    h.capturer.scene = 2
    h.connectivity.isConnected = false
    let calls = h.capturer.calls

    #expect(await h.scheduler.tick() == .skipped(.offline))
    #expect(h.capturer.calls == calls)
    #expect(h.describer.requests.isEmpty)
    #expect(h.arbiter.received.isEmpty)
}

@Test @MainActor func withoutConsentNoPhotoIsTakenAndNothingIsSaid() async {
    let h = makeHarness()
    defer { h.scheduler.stop() }
    h.consent.granted = false

    #expect(await h.scheduler.tick() == .skipped(.consentRequired))
    #expect(h.capturer.calls == 0)
    // Una automática nunca explica el consentimiento: eso lo hace Preferencias.
    #expect(h.consent.asked == 0)
    #expect(h.arbiter.received.isEmpty)
}

@Test @MainActor func aMissingOrUnclearPhotoIsSkippedQuietly() async {
    let h = makeHarness()
    defer { h.scheduler.stop() }
    h.capturer.unusable = true

    #expect(await h.scheduler.tick() == .skipped(.noFrame))
    #expect(h.arbiter.received.isEmpty)
}

@Test @MainActor func failuresAreSilentAndBackOff() async {
    let h = makeHarness()
    defer { h.scheduler.stop() }
    await h.scheduler.tick()
    h.clock.advance(10)
    h.capturer.scene = 2
    h.describer.error = HTTPClientError.statusCode(503)

    let first = await h.scheduler.tick()
    #expect(first == .requested(.unavailable(.serviceUnavailable)))
    #expect(h.arbiter.received.isEmpty)

    // Pasado el mínimo de 10 s, todavía espera la pausa de 30 s.
    h.clock.advance(11)
    #expect(await h.scheduler.tick() == .skipped(.backingOff))
    h.clock.advance(19)
    let second = await h.scheduler.tick()
    #expect(second == .requested(.unavailable(.serviceUnavailable)))

    // La segunda falla seguida duplica la pausa: 60 s.
    h.clock.advance(59)
    #expect(await h.scheduler.tick() == .skipped(.backingOff))
    h.describer.error = nil
    h.clock.advance(1)
    if case .requested(.described) = await h.scheduler.tick() {} else {
        Issue.record("debía recuperarse")
    }
    #expect(h.arbiter.received.count == 1)
}

@Test @MainActor func rateLimitingFromTheBackendIsSilentToo() async {
    let h = makeHarness()
    defer { h.scheduler.stop() }
    await h.scheduler.tick()
    h.clock.advance(10)
    h.capturer.scene = 2
    h.describer.error = HTTPClientError.statusCode(429)

    #expect(await h.scheduler.tick() == .requested(.unavailable(.rateLimited)))
    #expect(h.arbiter.received.isEmpty)
}

// MARK: Ciclo de vida

@Test @MainActor func revokingConsentStopsTheUpdates() async {
    let h = makeHarness()
    await h.scheduler.tick()

    h.service.cancel()

    #expect(h.scheduler.isRunning == false)
    #expect(await h.scheduler.tick() == .notRunning)
}

@Test @MainActor func eachRouteStartsFromScratch() async {
    let h = makeHarness()
    await h.scheduler.tick()
    h.scheduler.stop()
    #expect(await h.scheduler.tick() == .notRunning)

    h.scheduler.start()
    defer { h.scheduler.stop() }
    // Sin escena de referencia de la ruta anterior: la primera foto vuelve a ser la base.
    h.capturer.scene = 2
    #expect(await h.scheduler.tick() == .baselineSet)
}

@Test @MainActor func theAutoTriggerTravelsToTheBackend() {
    let frame = NarrationFrame(jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]), capturedAt: Date())
    let body = RemoteEnvironmentNarrationService.multipartBody(
        frame: frame, trigger: .auto, consentVersion: "v1", boundary: "b"
    )
    let text = String(decoding: body, as: UTF8.self)

    #expect(text.contains("name=\"trigger\"\r\n\r\nauto\r\n"))
}
