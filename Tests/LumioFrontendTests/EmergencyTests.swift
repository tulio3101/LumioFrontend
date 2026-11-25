import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

/// Botón de Emergencia (SCRUM-35): margen para cancelar, envío con ubicación, errores por
/// audio y háptica, y cliente del backend. El margen real es de 10 s; aquí cada segundo dura 1 ms.

private let baseURL = URL(string: "http://localhost:8000")!
private let keyA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
private let keyB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
private let bogota = EmergencyLocation(latitude: 4.6097, longitude: -74.0817, accuracyMeters: 14.6)
private let everyone = EmergencyDelivery(contactsTotal: 2, contactsSent: 2, locationIncluded: true)

@MainActor
private final class FakeEmergencyRemote: EmergencyRemoting {
    var result: Result<EmergencyDelivery, Error> = .success(everyone)
    private(set) var sent: [EmergencyAlert] = []

    func send(_ alert: EmergencyAlert) async throws -> EmergencyDelivery {
        sent.append(alert)
        return try result.get()
    }
}

@MainActor
private struct FakeLocator: EmergencyLocating {
    var location: EmergencyLocation?
    func currentLocation() async -> EmergencyLocation? { location }
}

@MainActor
private final class EmergencyConnectivity: ConnectivityObserving {
    var isConnected = true
    func start(onReconnect: @escaping @MainActor () -> Void) {}
}

@MainActor
private final class EmergencyHaptics: HapticFeedbackPlaying {
    private(set) var cues: [HapticCue] = []
    func play(_ cue: HapticCue) { cues.append(cue) }
}

@MainActor
private final class Ticks {
    private(set) var count = 0
    func tick() { count += 1 }
}

@MainActor
private struct EmergencyHarness {
    let remote = FakeEmergencyRemote()
    let connectivity = EmergencyConnectivity()
    let arbiter = SpyArbiter()
    let haptics = EmergencyHaptics()
    let tokens = InMemoryTokenStore(AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
    let ticks = Ticks()
    let service: EmergencyService
    private(set) var phases: PhaseLog

    @MainActor
    final class PhaseLog {
        var phases: [EmergencyPhase] = []
    }

    init(
        location: EmergencyLocation? = bogota,
        contactCount: Int? = 2,
        keys: [UUID] = [keyA, keyB],
        secondDuration: UInt64 = 1_000_000
    ) {
        let log = PhaseLog()
        phases = log
        var remaining = keys
        let ticks = ticks
        service = EmergencyService(
            remote: remote,
            locator: FakeLocator(location: location),
            connectivity: connectivity,
            contactCount: { contactCount },
            tokens: tokens,
            arbiter: arbiter,
            haptics: haptics,
            makeKey: { remaining.isEmpty ? UUID() : remaining.removeFirst() },
            sleep: { _ in
                await ticks.tick()
                try await Task.sleep(nanoseconds: secondDuration)
            }
        )
        service.onPhaseChange = { log.phases.append($0) }
    }

    var spoken: [String] { arbiter.received.map(\.text) }
    var lastSpoken: String? { spoken.last }

    /// Espera a que termine lo que está en curso (el margen dura unos milisegundos).
    func settle() async {
        for _ in 0..<2_000 where service.phase.isBusy { try? await Task.sleep(nanoseconds: 1_000_000) }
    }
}

// MARK: - Activación y margen

@Test @MainActor func emergencyActivatingGivesImmediateAudioAndHapticFeedback() {
    let harness = EmergencyHarness(secondDuration: 60_000_000_000)

    harness.service.activate()

    #expect(harness.service.phase == .countingDown(secondsRemaining: 10))
    #expect(harness.haptics.cues == [.emergencyActivated])
    let message = harness.arbiter.received.first
    #expect(message?.priority == .immediateRisk)
    #expect(message?.contextID == EmergencyService.contextID)
    let text = message?.text ?? ""
    #expect(text.contains("Emergencia activada"))
    #expect(text.contains("10 segundos"))
    #expect(text.contains("Cancelar"))
    #expect(text.contains("no sustituye a los servicios de emergencia"))
    #expect(text.contains("123"))
    harness.service.cancel()
}

@Test @MainActor func emergencyAlertIsSentOnlyAfterTheWholeMargin() async {
    let harness = EmergencyHarness()

    harness.service.activate()
    #expect(harness.remote.sent.isEmpty)
    await harness.settle()

    #expect(harness.ticks.count == 10)
    #expect(harness.remote.sent == [EmergencyAlert(idempotencyKey: keyA, location: bogota)])
    #expect(harness.service.phase == .sent(everyone))
}

@Test @MainActor func emergencyCountdownGoesFromTenToOneThenSends() async {
    let harness = EmergencyHarness()

    harness.service.activate()
    await harness.settle()

    let counting = harness.phases.phases.compactMap { phase -> Int? in
        if case .countingDown(let seconds) = phase { seconds } else { nil }
    }
    #expect(Array(Set(counting)).sorted() == Array(1...10))
    #expect(counting == counting.sorted(by: >))
    #expect(Array(harness.phases.phases.suffix(2)) == [.sending, .sent(everyone)])
}

@Test @MainActor func emergencyRemindsAtFiveSeconds() async {
    let harness = EmergencyHarness()

    harness.service.activate()
    await harness.settle()

    #expect(harness.spoken.contains("Se envía en 5 segundos. Toca Cancelar para detenerla."))
}

@Test @MainActor func emergencyCancellingDuringTheMarginSendsNothingAndSaysSo() async {
    let harness = EmergencyHarness(secondDuration: 60_000_000_000)
    harness.service.activate()
    try? await Task.sleep(nanoseconds: 5_000_000)

    harness.service.cancel()
    try? await Task.sleep(nanoseconds: 20_000_000)

    #expect(harness.service.phase == .cancelled)
    #expect(harness.remote.sent.isEmpty)
    #expect(harness.lastSpoken == "Alerta cancelada. No se envió nada.")
    #expect(harness.haptics.cues == [.emergencyActivated])
}

@Test @MainActor func emergencyCancelDoesNothingWhenThereIsNoMargin() {
    let harness = EmergencyHarness()

    harness.service.cancel()

    #expect(harness.service.phase == .idle)
    #expect(harness.arbiter.received.isEmpty)
}

@Test @MainActor func emergencyCannotBeCancelledOnceItIsSending() async {
    let harness = EmergencyHarness()
    harness.service.activate()
    for _ in 0..<2_000 {
        if harness.service.phase == .sending || !harness.service.phase.isBusy { break }
        try? await Task.sleep(nanoseconds: 500_000)
    }

    harness.service.cancel()
    await harness.settle()

    #expect(harness.service.phase != .cancelled)
    #expect(harness.remote.sent.count == 1)
}

@Test @MainActor func emergencyActivatingTwiceDuringTheMarginSendsOnce() async {
    let harness = EmergencyHarness()

    harness.service.activate()
    harness.service.activate()
    await harness.settle()

    #expect(harness.remote.sent.count == 1)
    #expect(harness.haptics.cues.filter { $0 == .emergencyActivated }.count == 1)
}

@Test @MainActor func emergencyCanBeActivatedAgainWithANewKey() async {
    let harness = EmergencyHarness()
    harness.service.activate()
    await harness.settle()
    harness.service.dismiss()

    harness.service.activate()
    await harness.settle()

    #expect(harness.remote.sent.map(\.idempotencyKey) == [keyA, keyB])
}

// MARK: - Resultado

@Test @MainActor func emergencySuccessIsAnnouncedWithHaptic() async {
    let harness = EmergencyHarness()

    harness.service.activate()
    await harness.settle()

    #expect(harness.lastSpoken == "Alerta enviada a 2 contactos.")
    #expect(harness.haptics.cues == [.emergencyActivated, .emergencySent])
}

@Test @MainActor func emergencySingularContact() {
    let one = EmergencyDelivery(contactsTotal: 1, contactsSent: 1, locationIncluded: true)

    #expect(EmergencyAnnouncements.sent(one) == "Alerta enviada a 1 contacto.")
}

@Test @MainActor func emergencyWithoutLocationIsSentAnywayAndSaysSo() async {
    let harness = EmergencyHarness(location: nil)
    harness.remote.result = .success(EmergencyDelivery(contactsTotal: 2, contactsSent: 2, locationIncluded: false))

    harness.service.activate()
    await harness.settle()

    #expect(harness.remote.sent == [EmergencyAlert(idempotencyKey: keyA, location: nil)])
    #expect(harness.lastSpoken == "Alerta enviada a 2 contactos. No se pudo obtener tu ubicación, así que se envió sin ella.")
}

@Test @MainActor func emergencyPartialDeliveryNamesHowManyReceivedIt() async {
    let harness = EmergencyHarness()
    let partial = EmergencyDelivery(contactsTotal: 3, contactsSent: 1, locationIncluded: true)
    harness.remote.result = .success(partial)

    harness.service.activate()
    await harness.settle()

    #expect(harness.service.phase == .sent(partial))
    #expect(harness.lastSpoken?.hasPrefix("Alerta enviada solo a 1 de 3 contactos. El correo no llegó a los demás.") == true)
    #expect(harness.haptics.cues.last == .emergencySent)
}

// MARK: - Errores

@Test @MainActor func emergencyWithoutContactsIsReportedAndNothingIsSent() async {
    let harness = EmergencyHarness(contactCount: 0)

    harness.service.activate()
    await harness.settle()

    #expect(harness.service.phase == .failed(.noContacts))
    #expect(harness.remote.sent.isEmpty)
    #expect(harness.lastSpoken?.hasPrefix("No tienes contactos de confianza, así que no se envió la alerta.") == true)
    #expect(harness.haptics.cues == [.emergencyActivated, .emergencyFailed])
}

@Test @MainActor func emergencyWithUnknownContactCountLetsTheBackendDecide() async {
    let harness = EmergencyHarness(contactCount: nil)
    harness.remote.result = .failure(HTTPClientError.statusCode(409))

    harness.service.activate()
    await harness.settle()

    #expect(harness.remote.sent.count == 1)
    #expect(harness.service.phase == .failed(.noContacts))
}

@Test @MainActor func emergencyWithoutConnectivityReportsItWithoutTryingToSend() async {
    let harness = EmergencyHarness()
    harness.connectivity.isConnected = false

    harness.service.activate()
    await harness.settle()

    #expect(harness.service.phase == .failed(.offline))
    #expect(harness.remote.sent.isEmpty)
    #expect(harness.lastSpoken?.hasPrefix("Sin conexión. No se pudo enviar la alerta.") == true)
    #expect(harness.haptics.cues.last == .emergencyFailed)
}

@Test @MainActor func emergencyNetworkErrorFromTheServerCallIsOffline() async {
    let harness = EmergencyHarness()
    harness.remote.result = .failure(URLError(.notConnectedToInternet))

    harness.service.activate()
    await harness.settle()

    #expect(harness.service.phase == .failed(.offline))
}

@Test @MainActor func emergencyExpiredSessionClearsTheTokens() async {
    let harness = EmergencyHarness()
    harness.remote.result = .failure(AuthenticationError.sessionExpired)

    harness.service.activate()
    await harness.settle()

    #expect(harness.service.phase == .failed(.sessionExpired))
    #expect(harness.tokens.load() == nil)
}

@Test func emergencyBackendErrorsAreClassified() {
    #expect(EmergencyService.failure(for: URLError(.notConnectedToInternet)) == .offline)
    #expect(EmergencyService.failure(for: URLError(.timedOut)) == .offline)
    #expect(EmergencyService.failure(for: URLError(.badServerResponse)) == .server)
    #expect(EmergencyService.failure(for: AuthenticationError.sessionExpired) == .sessionExpired)
    #expect(EmergencyService.failure(for: AuthenticationError.notSignedIn) == .sessionExpired)
    #expect(EmergencyService.failure(for: HTTPClientError.statusCode(401)) == .sessionExpired)
    #expect(EmergencyService.failure(for: HTTPClientError.statusCode(409)) == .noContacts)
    #expect(EmergencyService.failure(for: HTTPClientError.statusCode(502)) == .deliveryFailed)
    #expect(EmergencyService.failure(for: HTTPClientError.statusCode(500)) == .server)
    #expect(EmergencyService.failure(for: HTTPClientError.statusCode(422)) == .server)
    #expect(EmergencyService.failure(for: FeatureUnavailable.authentication) == .server)
}

@Test func emergencyEveryFailureRemindsThatItDoesNotReplaceEmergencyServices() {
    for failure in [EmergencyFailure.offline, .sessionExpired, .noContacts, .deliveryFailed, .server] {
        let text = EmergencyAnnouncements.failed(failure)
        #expect(text.contains("no sustituye a los servicios de emergencia"), "\(failure)")
        #expect(text.contains("123"), "\(failure)")
    }
}

// MARK: - Reintentar y descartar

@Test @MainActor func emergencyRetrySendsAgainWithTheSameKeyAndNoNewMargin() async {
    let harness = EmergencyHarness()
    harness.remote.result = .failure(HTTPClientError.statusCode(502))
    harness.service.activate()
    await harness.settle()
    let ticksAfterFirstAttempt = harness.ticks.count
    harness.remote.result = .success(everyone)

    harness.service.retry()
    await harness.settle()

    #expect(harness.remote.sent.map(\.idempotencyKey) == [keyA, keyA])
    #expect(harness.remote.sent.map(\.location) == [bogota, bogota])
    #expect(harness.ticks.count == ticksAfterFirstAttempt)
    #expect(harness.service.phase == .sent(everyone))
    #expect(harness.lastSpoken == "Alerta enviada a 2 contactos.")
}

@Test @MainActor func emergencyRetryIsOfferedOnlyWhenItCanHelp() async {
    for (failure, canRetry) in [
        (EmergencyFailure.offline, true), (.deliveryFailed, true), (.server, true),
        (.sessionExpired, false), (.noContacts, false),
    ] {
        #expect(failure.canRetry == canRetry, "\(failure)")
    }
    let harness = EmergencyHarness(contactCount: 0)
    harness.service.activate()
    await harness.settle()

    harness.service.retry()
    await harness.settle()

    #expect(harness.remote.sent.isEmpty)
    #expect(harness.service.phase == .failed(.noContacts))
}

@Test @MainActor func emergencyRetryDoesNothingWithoutAFailure() {
    let harness = EmergencyHarness()

    harness.service.retry()

    #expect(harness.service.phase == .idle)
    #expect(harness.remote.sent.isEmpty)
}

@Test @MainActor func emergencyDismissClearsTheResultButNeverAnAlertInProgress() async {
    let harness = EmergencyHarness(secondDuration: 60_000_000_000)
    harness.service.activate()

    harness.service.dismiss()
    #expect(harness.service.phase == .countingDown(secondsRemaining: 10))

    harness.service.cancel()
    harness.service.dismiss()
    #expect(harness.service.phase == .idle)
}

@Test @MainActor func emergencyANewMessageReplacesThePreviousOne() async {
    let harness = EmergencyHarness()

    harness.service.activate()
    await harness.settle()

    #expect(harness.arbiter.cancelledContexts.allSatisfy { $0 == [EmergencyService.contextID] })
    #expect(harness.arbiter.cancelledContexts.count == harness.arbiter.received.count)
}

// MARK: - Backend

private func json(_ request: URLRequest?) throws -> [String: Any] {
    let body = try #require(request?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
}

private let sosRead = Data("""
{"id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","status":"sent","contacts_total":2,"contacts_sent":2,
"location_included":true,"created_at":"2026-11-24T10:00:00Z"}
""".utf8)

@Test func emergencyPostsTheAlertWithItsLocationAndKey() async throws {
    let http = FakeHTTPClient(response: .success(sosRead))

    let delivery = try await RemoteEmergencyService(client: http, baseURL: baseURL)
        .send(EmergencyAlert(idempotencyKey: keyA, location: bogota))

    #expect(delivery == everyone)
    let request = try #require(http.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "http://localhost:8000/sos")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try json(request)
    #expect(body["idempotency_key"] as? String == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    #expect(body["latitude"] as? Double == 4.6097)
    #expect(body["longitude"] as? Double == -74.0817)
    #expect(body["accuracy_m"] as? Double == 14.6)
}

@Test func emergencyWithoutLocationOmitsTheThreeLocationFields() async throws {
    let http = FakeHTTPClient(response: .success(sosRead))

    _ = try await RemoteEmergencyService(client: http, baseURL: baseURL)
        .send(EmergencyAlert(idempotencyKey: keyB, location: nil))

    #expect(try json(http.requests.first).keys.sorted() == ["idempotency_key"])
}

@Test func emergencyLocationWithoutAccuracyOmitsOnlyTheAccuracy() async throws {
    let http = FakeHTTPClient(response: .success(sosRead))
    let location = EmergencyLocation(latitude: 1, longitude: 2, accuracyMeters: nil)

    _ = try await RemoteEmergencyService(client: http, baseURL: baseURL)
        .send(EmergencyAlert(idempotencyKey: keyA, location: location))

    #expect(try json(http.requests.first).keys.sorted() == ["idempotency_key", "latitude", "longitude"])
}

@Test func emergencyWithoutBackendIsUnavailable() async {
    let remote = RemoteEmergencyService(client: FakeHTTPClient(response: .success(sosRead)), baseURL: nil)

    await #expect(throws: FeatureUnavailable.self) {
        try await remote.send(EmergencyAlert(idempotencyKey: keyA, location: nil))
    }
}

// MARK: - Flujo integrado (AudioArbiter real y sesión con refresh)

@MainActor
private struct EmergencyFlow {
    let player = FakeAudioPlayer()
    let arbiter: AudioArbiterService
    let http: FakeHTTPClient
    let tokens = InMemoryTokenStore(AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
    let haptics = EmergencyHaptics()
    let service: EmergencyService

    init(backend: Result<Data, Error>) {
        arbiter = AudioArbiterService(player: player)
        http = FakeHTTPClient(response: backend)
        let authorized = AuthorizedHTTPClient(
            base: http, api: AuthAPI(client: http, baseURL: baseURL), store: tokens
        )
        service = EmergencyService(
            remote: RemoteEmergencyService(client: authorized, baseURL: baseURL),
            locator: FakeLocator(location: bogota),
            connectivity: EmergencyConnectivity(),
            contactCount: { 2 },
            tokens: tokens,
            arbiter: arbiter,
            haptics: haptics,
            makeKey: { keyA },
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) }
        )
    }

    func settle() async {
        for _ in 0..<2_000 where service.phase.isBusy { try? await Task.sleep(nanoseconds: 1_000_000) }
    }
}

@Test @MainActor func emergencyIsSentWithTheSessionAndAnnouncedByTheArbiter() async throws {
    let flow = EmergencyFlow(backend: .success(sosRead))

    flow.service.activate()
    await flow.settle()

    #expect(flow.service.phase == .sent(everyone))
    #expect(flow.http.requests.map { $0.url?.path } == ["/sos"])
    #expect(flow.http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    #expect(flow.arbiter.currentMessage?.text == "Alerta enviada a 2 contactos.")
    #expect(flow.arbiter.currentMessage?.priority == .immediateRisk)
}

@Test @MainActor func emergencyExpiredAccessTokenIsRenewedBeforeSending() async throws {
    let flow = EmergencyFlow(backend: .success(sosRead))
    let tokenPair = Data("""
    {"access_token":"access-2","refresh_token":"refresh-2","token_type":"bearer","expires_in":900}
    """.utf8)
    flow.http.queued = [.failure(HTTPClientError.statusCode(401)), .success(tokenPair)]

    flow.service.activate()
    await flow.settle()

    #expect(flow.service.phase == .sent(everyone))
    #expect(flow.http.requests.map { $0.url?.path } == ["/sos", "/users/refresh", "/sos"])
    #expect(flow.http.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
}

@Test @MainActor func emergencyRejectedSessionClearsTokensAndIsAnnounced() async {
    let flow = EmergencyFlow(backend: .failure(HTTPClientError.statusCode(401)))

    flow.service.activate()
    await flow.settle()

    #expect(flow.service.phase == .failed(.sessionExpired))
    #expect(flow.tokens.load() == nil)
    #expect(flow.arbiter.currentMessage?.text.hasPrefix("Tu sesión expiró y no se envió la alerta.") == true)
}
