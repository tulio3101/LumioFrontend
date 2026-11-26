import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

// SCRUM-38: Narración del Entorno (captura → backend → audio P3 → fallas).

private let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
private let photo = NarrationFrame(jpeg: Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9]), capturedAt: capturedAt)

private final class FakeCapturer: NarrationFrameCapturing {
    var result: NarrationCapture = .frame(photo)
    private(set) var calls = 0
    /// Se ejecuta durante la captura (p. ej., retirar el consentimiento a mitad).
    var onCapture: (@MainActor () -> Void)?

    func captureNarrationFrame() async -> NarrationCapture {
        calls += 1
        if let onCapture { await onCapture() }
        return result
    }
}

private final class FakeDescriber: EnvironmentDescribing, @unchecked Sendable {
    var text = "Delante hay un cruce peatonal con semáforo."
    var error: Error?
    private(set) var requests: [(frame: NarrationFrame, trigger: NarrationTrigger, consent: String)] = []
    /// Si existe, la descripción espera a que la prueba la suelte.
    var gate: AsyncStream<Void>?

    func describe(
        _ frame: NarrationFrame, trigger: NarrationTrigger, consentVersion: String
    ) async throws -> String {
        requests.append((frame, trigger, consentVersion))
        if let gate { for await _ in gate { break } }
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
    private(set) var cancelled: [Set<String>] = []
    func receive(_ message: AudioMessage) { received.append(message) }
    func processNext() {}
    func playbackFinished(token: PlaybackToken) {}
    func discardIrrelevant() {}
    func resetSession() {}
    func updateContext(_ context: AudioDecisionContext) {}
    func cancel(contextIDs: Set<String>) { cancelled.append(contextIDs) }

    var narrations: [AudioMessage] { received.filter { $0.contextID == NarrationAudio.contextID } }
    var notices: [AudioMessage] {
        received.filter { $0.contextID == EnvironmentNarrationService.statusContextID }
    }
}

private final class FakeTokens: TokenStoring, @unchecked Sendable {
    private(set) var cleared = false
    func load() -> AuthTokens? { nil }
    func save(_ tokens: AuthTokens) throws {}
    func clear() { cleared = true }
}

@MainActor
private struct Harness {
    let service: EnvironmentNarrationService
    let capturer: FakeCapturer
    let describer: FakeDescriber
    let consent: FakeConsent
    let connectivity: FakeConnectivity
    let arbiter: RecordingArbiter
    let tokens: FakeTokens
}

@MainActor
private func makeHarness(
    capturer: FakeCapturer? = FakeCapturer(),
    responseAge: TimeInterval = 1,
    noticeSleep: @escaping (TimeInterval) async throws -> Void = { _ in
        // Por defecto «Describiendo…» nunca llega a sonar.
        try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
    }
) -> Harness {
    let describer = FakeDescriber()
    let consent = FakeConsent()
    let connectivity = FakeConnectivity()
    let arbiter = RecordingArbiter()
    let tokens = FakeTokens()
    let service = EnvironmentNarrationService(
        capturer: capturer,
        describer: describer,
        consent: consent,
        connectivity: connectivity,
        arbiter: arbiter,
        tokens: tokens,
        sleep: noticeSleep,
        now: { capturedAt.addingTimeInterval(responseAge) }
    )
    return Harness(
        service: service, capturer: capturer ?? FakeCapturer(), describer: describer,
        consent: consent, connectivity: connectivity, arbiter: arbiter, tokens: tokens
    )
}

// MARK: Camino feliz (SCRUM-261 a 265)

@Test @MainActor func describesTheEnvironmentAsP3() async {
    let h = makeHarness()

    let outcome = await h.service.describeEnvironment()

    #expect(outcome == .described("Delante hay un cruce peatonal con semáforo."))
    #expect(h.capturer.calls == 1)
    #expect(h.describer.requests.count == 1)
    #expect(h.describer.requests.first?.frame == photo)
    #expect(h.describer.requests.first?.trigger == .gesture)
    #expect(h.describer.requests.first?.consent == NarrationConsentPolicy.currentVersion)
    let message = h.arbiter.narrations.first
    #expect(message?.priority == .environmentInformation)
    #expect(message?.text == "Delante hay un cruce peatonal con semáforo.")
    #expect(message?.createdAt == capturedAt)
    #expect(message?.captureSequence == 1)
    #expect(h.arbiter.notices.isEmpty)
    #expect(h.service.isDescribing == false)
}

@Test @MainActor func eachDescriptionGetsANewerCaptureSequence() async {
    let h = makeHarness()

    await h.service.describeEnvironment()
    await h.service.describeEnvironment()

    #expect(h.arbiter.narrations.map(\.captureSequence) == [1, 2])
}

// MARK: Consentimiento (SCRUM-324)

@Test @MainActor func withoutConsentNoPhotoIsTaken() async {
    let h = makeHarness()
    h.consent.granted = false

    let outcome = await h.service.describeEnvironment()

    #expect(outcome == .consentRequired)
    #expect(h.consent.asked == 1)
    #expect(h.capturer.calls == 0)
    #expect(h.describer.requests.isEmpty)
    // El servicio de consentimiento es quien lo explica.
    #expect(h.arbiter.received.isEmpty)
}

@Test @MainActor func consentRevokedDuringCaptureNeverUploads() async {
    let h = makeHarness()
    h.capturer.onCapture = { h.consent.granted = false }

    let outcome = await h.service.describeEnvironment()

    #expect(outcome == .cancelled)
    #expect(h.describer.requests.isEmpty)
    #expect(h.arbiter.narrations.isEmpty)
}

// MARK: Sin conexión y sin cámara (SCRUM-262, 267)

@Test @MainActor func offlineIsReportedWithoutTakingAPhoto() async {
    let h = makeHarness()
    h.connectivity.isConnected = false

    let outcome = await h.service.describeEnvironment()

    #expect(outcome == .unavailable(.offline))
    #expect(h.capturer.calls == 0)
    #expect(h.describer.requests.isEmpty)
    #expect(h.arbiter.notices.map(\.text) == [EnvironmentNarrationMessages.message(for: .offline)])
    #expect(h.arbiter.notices.first?.priority == .routeInformation)
}

@Test @MainActor func withoutCameraItSaysSo() async {
    let h = makeHarness(capturer: nil)

    #expect(await h.service.describeEnvironment() == .unavailable(.cameraInactive))
    #expect(h.describer.requests.isEmpty)
}

@Test @MainActor func cameraNotRunningIsReported() async {
    let h = makeHarness()
    h.capturer.result = .cameraInactive

    #expect(await h.service.describeEnvironment() == .unavailable(.cameraInactive))
    #expect(h.describer.requests.isEmpty)
    #expect(h.arbiter.notices.first?.text.contains("Inicia un trayecto") == true)
}

@Test @MainActor func blurryOrCoveredCameraIsReported() async {
    let h = makeHarness()
    h.capturer.result = .noUsableFrame

    #expect(await h.service.describeEnvironment() == .unavailable(.noUsableFrame))
    #expect(h.describer.requests.isEmpty)
}

// MARK: Fallas del backend (SCRUM-266, 267)

@Test @MainActor func backendFailureIsReportedAndNothingIsNarrated() async {
    let h = makeHarness()
    h.describer.error = HTTPClientError.statusCode(503)

    let outcome = await h.service.describeEnvironment()

    #expect(outcome == .unavailable(.serviceUnavailable))
    #expect(h.arbiter.narrations.isEmpty)
    let notice = h.arbiter.notices.last?.text ?? ""
    #expect(notice.contains("no está disponible"))
    #expect(notice.contains("detección de obstáculos sigue activa"))
    #expect(h.service.isDescribing == false)
}

@Test @MainActor func afterAFailureTheNextRequestWorks() async {
    let h = makeHarness()
    h.describer.error = URLError(.notConnectedToInternet)
    #expect(await h.service.describeEnvironment() == .unavailable(.offline))

    h.describer.error = nil
    #expect(await h.service.describeEnvironment() == .described(h.describer.text))
}

@Test @MainActor func expiredSessionClearsTokens() async {
    let h = makeHarness()
    h.describer.error = HTTPClientError.statusCode(401)

    #expect(await h.service.describeEnvironment() == .unavailable(.sessionRequired))
    #expect(h.tokens.cleared)
}

@Test func errorsMapToWhatTheUserHears() {
    let cases: [(Error, EnvironmentNarrationUnavailable)] = [
        (URLError(.timedOut), .timedOut),
        (URLError(.notConnectedToInternet), .offline),
        (URLError(.networkConnectionLost), .offline),
        (AuthenticationError.notSignedIn, .sessionRequired),
        (AuthenticationError.sessionExpired, .sessionRequired),
        (HTTPClientError.statusCode(401), .sessionRequired),
        (FeatureUnavailable.authentication, .notConfigured),
        (HTTPClientError.statusCode(429), .rateLimited),
        (HTTPClientError.statusCode(504), .timedOut),
        (HTTPClientError.statusCode(503), .serviceUnavailable),
        (HTTPClientError.statusCode(500), .serviceUnavailable),
        (HTTPClientError.statusCode(403), .serviceUnavailable),
        (HTTPClientError.invalidResponse, .serviceUnavailable),
    ]
    for (error, expected) in cases {
        #expect(EnvironmentNarrationService.reason(for: error) == expected, "\(error)")
    }
}

// MARK: Respuestas viejas (ADR-308)

@Test @MainActor func aDescriptionThatArrivesTooLateIsDiscarded() async {
    let h = makeHarness(responseAge: EnvironmentNarrationService.maxResponseAge + 0.5)

    let outcome = await h.service.describeEnvironment()

    #expect(outcome == .unavailable(.stale))
    #expect(h.arbiter.narrations.isEmpty)
}

@Test @MainActor func aDescriptionJustInTimeIsNarrated() async {
    let h = makeHarness(responseAge: EnvironmentNarrationService.maxResponseAge)

    #expect(await h.service.describeEnvironment() == .described(h.describer.text))
}

// MARK: Una sola solicitud en vuelo

@Test @MainActor func onlyOneRequestInFlight() async {
    let h = makeHarness()
    let (gate, release) = AsyncStream<Void>.makeStream()
    h.describer.gate = gate

    let first = Task { await h.service.describeEnvironment() }
    while h.describer.requests.isEmpty { await Task.yield() }

    #expect(h.service.isDescribing)
    #expect(await h.service.describeEnvironment() == .alreadyDescribing)
    #expect(h.capturer.calls == 1)

    release.yield()
    #expect(await first.value == .described(h.describer.text))
}

@Test @MainActor func slowResponsesAnnounceDescribing() async {
    let h = makeHarness(noticeSleep: { _ in })
    let (gate, release) = AsyncStream<Void>.makeStream()
    h.describer.gate = gate

    let request = Task { await h.service.describeEnvironment() }
    while h.arbiter.notices.isEmpty { await Task.yield() }

    #expect(h.arbiter.notices.first?.text == EnvironmentNarrationMessages.describing)
    #expect(h.arbiter.notices.first?.priority == .environmentInformation)

    release.yield()
    _ = await request.value
    // «Describiendo…» se corta antes de que suene la descripción.
    #expect(h.arbiter.cancelled.contains([EnvironmentNarrationService.statusContextID]))
    #expect(h.arbiter.narrations.count == 1)
}

@Test @MainActor func cancelStopsTheRequestAndItsAudio() async {
    let h = makeHarness()
    let (gate, release) = AsyncStream<Void>.makeStream()
    h.describer.gate = gate

    h.service.requestDescription()
    while h.describer.requests.isEmpty { await Task.yield() }
    h.service.cancel()
    release.yield()
    for _ in 0..<50 { await Task.yield() }

    #expect(h.arbiter.narrations.isEmpty)
    #expect(h.arbiter.cancelled.contains([NarrationAudio.contextID, EnvironmentNarrationService.statusContextID]))
    #expect(h.service.isDescribing == false)
}

// MARK: Contrato con el backend (ADR-308 §6)

private final class CapturingHTTPClient: HTTPClient, @unchecked Sendable {
    private(set) var request: URLRequest?
    var response = Data(#"{"text":"Hay una puerta a tu derecha.","model":"us.anthropic.claude-haiku-5-5","latency_ms":870}"#.utf8)

    func send(_ request: URLRequest) async throws -> Data {
        self.request = request
        return response
    }
}

@Test func remoteServiceSendsMultipartToVisionAnalyze() async throws {
    let client = CapturingHTTPClient()
    let remote = RemoteEnvironmentNarrationService(
        client: client,
        baseURL: URL(string: "https://api.example.com")!,
        makeBoundary: { "limite" }
    )

    let text = try await remote.describe(photo, trigger: .gesture, consentVersion: "2026-11-1")

    #expect(text == "Hay una puerta a tu derecha.")
    let request = try #require(client.request)
    #expect(request.url?.absoluteString == "https://api.example.com/vision/analyze")
    #expect(request.httpMethod == "POST")
    #expect(request.timeoutInterval == 5)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=limite")
    let body = try #require(request.httpBody)
    let printable = String(decoding: body, as: UTF8.self)
    #expect(printable.contains("name=\"consent_version\"\r\n\r\n2026-11-1\r\n"))
    #expect(printable.contains("name=\"trigger\"\r\n\r\ngesture\r\n"))
    #expect(printable.contains("name=\"captured_at\"\r\n\r\n2027-01-15T08:00:00.000Z\r\n"))
    #expect(printable.contains("name=\"image\"; filename=\"frame.jpg\"\r\nContent-Type: image/jpeg"))
    #expect(body.range(of: photo.jpeg) != nil)
    #expect(printable.hasSuffix("--limite--\r\n"))
    // Nada de ubicación ni base64 (ADR-308).
    #expect(!printable.contains("location"))
    #expect(!printable.contains("base64"))
}

@Test func remoteServiceWithoutBackendIsNotConfigured() async {
    let remote = RemoteEnvironmentNarrationService(client: CapturingHTTPClient(), baseURL: nil)

    await #expect(throws: FeatureUnavailable.self) {
        try await remote.describe(photo, trigger: .gesture, consentVersion: "2026-11-1")
    }
}

@Test func responseHasNoAlertLevel() throws {
    let data = Data(#"{"text":"Hay un parque","model":"m","latency_ms":12}"#.utf8)
    let response = try JSONDecoder().decode(VisionAnalysisResponseDTO.self, from: data)
    #expect(response == VisionAnalysisResponseDTO(text: "Hay un parque", model: "m", latencyMs: 12))
}
