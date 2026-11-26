import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

// SCRUM-25: Compartir Ubicación. Backend, GPS, red y audio falsos.

private let t0 = Date(timeIntervalSince1970: 2_000_000_000)
private let here = GeoCoordinate(latitude: 4.6097, longitude: -74.0817)

@MainActor
private final class Clock {
    var now = t0
}

private final class FakeRemote: LocationSharingRemoting, @unchecked Sendable {
    var startError: Error?
    var updateErrors: [Error] = []
    var stopError: Error?
    var share = LocationShare(id: UUID(), expiresAt: t0.addingTimeInterval(3600), contactsTotal: 2, contactsSent: 2)
    private(set) var starts: [(SharedPosition, Int)] = []
    private(set) var updates: [SharedPosition] = []
    private(set) var stops: [UUID] = []

    func start(at position: SharedPosition, durationMinutes: Int) async throws -> LocationShare {
        starts.append((position, durationMinutes))
        if let startError { throw startError }
        return share
    }

    func update(_ shareID: UUID, to position: SharedPosition) async throws {
        updates.append(position)
        if !updateErrors.isEmpty { throw updateErrors.removeFirst() }
    }

    func stop(_ shareID: UUID) async throws {
        stops.append(shareID)
        if let stopError { throw stopError }
    }
}

@MainActor
private final class FakeLocation: CurrentLocationProviding {
    var error: Error?
    func currentLocation() async throws -> GeoCoordinate {
        if let error { throw error }
        return here
    }
}

private final class Tokens: TokenStoring, @unchecked Sendable {
    private(set) var cleared = false
    func load() -> AuthTokens? { nil }
    func save(_ tokens: AuthTokens) throws {}
    func clear() { cleared = true }
}

/// Cada espera del ciclo avanza el reloj 30 s y, cuando se agotan las vueltas programadas,
/// cancela para que la prueba termine.
@MainActor
private final class Rounds {
    var remaining = 0
    var beforeEach: [() -> Void] = []
}

@MainActor
private struct Harness {
    let clock = Clock()
    let remote = FakeRemote()
    let location = FakeLocation()
    let connectivity = FakeConnectivity()
    let arbiter = SpyArbiter()
    let tokens = Tokens()
    let rounds = Rounds()
    let service: LocationSharingService

    init() {
        let clock = clock
        let rounds = rounds
        service = LocationSharingService(
            remote: remote, location: location, connectivity: connectivity, arbiter: arbiter,
            tokens: tokens,
            sleep: { seconds in
                try await MainActor.run {
                    guard rounds.remaining > 0 else { throw CancellationError() }
                    rounds.remaining -= 1
                    clock.now = clock.now.addingTimeInterval(seconds)
                    if !rounds.beforeEach.isEmpty { rounds.beforeEach.removeFirst()() }
                }
            },
            now: { clock.now },
            runsUpdateLoop: false
        )
    }

    var spoken: [String] { arbiter.received.map(\.text) }

    /// Corre `count` vueltas del ciclo de actualización.
    func run(rounds count: Int, _ steps: [() -> Void] = []) async {
        guard case .sharing(let share, _) = service.state else { return }
        rounds.remaining = count
        rounds.beforeEach = steps
        await service.keepSharing(share)
    }
}

// MARK: Empezar

@Test @MainActor func startingSharesTheCurrentPositionAndSaysSo() async {
    let h = Harness()
    #expect(await h.service.start(durationMinutes: 30) == nil)
    #expect(h.remote.starts.first?.0 == SharedPosition(latitude: here.latitude, longitude: here.longitude, accuracyMeters: nil))
    #expect(h.remote.starts.first?.1 == 30)
    #expect(h.service.isSharing)
    #expect(h.spoken.last?.hasPrefix("Estás compartiendo tu ubicación con 2 contactos hasta las") == true)
    #expect(h.arbiter.received.last?.priority == .routeInformation)
}

@Test @MainActor func partialDeliveryIsReported() async {
    let h = Harness()
    h.remote.share = LocationShare(id: UUID(), expiresAt: t0.addingTimeInterval(600), contactsTotal: 3, contactsSent: 2)
    await h.service.start()
    #expect(h.spoken.last?.hasSuffix("No se pudo avisar a 1.") == true)
}

@Test @MainActor func withoutConnectionNothingStarts() async {
    let h = Harness()
    h.connectivity.isConnected = false
    #expect(await h.service.start() == .offline)
    #expect(h.remote.starts.isEmpty)
    #expect(h.service.state == .idle)
    #expect(h.spoken.last == LocationSharingAnnouncements.failure(.offline))
}

@Test @MainActor func withoutLocationPermissionItExplainsHowToEnableIt() async {
    let h = Harness()
    h.location.error = RouteCreationError.locationPermissionDenied
    #expect(await h.service.start() == .locationPermissionDenied)
    #expect(h.remote.starts.isEmpty)
    #expect(h.spoken.last?.contains("Preferencias, Permisos") == true)
}

@Test(arguments: [
    (HTTPClientError.statusCode(409) as Error, LocationSharingFailure.noTrustedContacts),
    (HTTPClientError.statusCode(502), .deliveryFailed),
    (HTTPClientError.statusCode(401), .sessionRequired),
    (HTTPClientError.statusCode(500), .serviceUnavailable),
    (URLError(.notConnectedToInternet), .offline),
    (FeatureUnavailable.authentication, .notConfigured),
])
@MainActor func backendFailuresAreSpoken(error: Error, expected: LocationSharingFailure) async {
    let h = Harness()
    h.remote.startError = error
    #expect(await h.service.start() == expected)
    #expect(h.service.state == .idle)
    #expect(h.spoken.last == LocationSharingAnnouncements.failure(expected))
    #expect(h.tokens.cleared == (expected == .sessionRequired))
}

// MARK: Mientras se comparte

@Test @MainActor func positionIsUpdatedEveryInterval() async {
    let h = Harness()
    await h.service.start()
    await h.run(rounds: 3)
    #expect(h.remote.updates.count == 3)
    #expect(h.service.isSharing)
}

@Test @MainActor func losingTheConnectionIsSaidOnceAndRecoveringToo() async {
    let h = Harness()
    await h.service.start()
    let connectivity = h.connectivity
    await h.run(rounds: 4, [
        { connectivity.isConnected = false },
        {},
        { connectivity.isConnected = true },
        {},
    ])
    #expect(h.spoken.filter { $0 == LocationSharingAnnouncements.offline }.count == 1)
    #expect(h.spoken.filter { $0 == LocationSharingAnnouncements.reconnected }.count == 1)
    #expect(h.remote.updates.count == 2)
    #expect(h.service.state == .sharing(h.remote.share, isOffline: false))
}

@Test @MainActor func aNetworkFailureWhileUpdatingCountsAsOffline() async {
    let h = Harness()
    await h.service.start()
    h.remote.updateErrors = [URLError(.networkConnectionLost)]
    await h.run(rounds: 1)
    #expect(h.service.state == .sharing(h.remote.share, isOffline: true))
}

@Test @MainActor func itEndsWhenTheTimeRunsOut() async {
    let h = Harness()
    h.remote.share = LocationShare(id: UUID(), expiresAt: t0.addingTimeInterval(45), contactsTotal: 1, contactsSent: 1)
    await h.service.start()
    await h.run(rounds: 5)
    #expect(h.service.state == .idle)
    #expect(h.spoken.last == LocationSharingAnnouncements.expired)
    #expect(h.remote.updates.count == 1)
}

@Test @MainActor func itEndsWhenTheBackendSaysItIsOver() async {
    let h = Harness()
    await h.service.start()
    h.remote.updateErrors = [HTTPClientError.statusCode(410)]
    await h.run(rounds: 3)
    #expect(h.service.state == .idle)
    #expect(h.spoken.last == LocationSharingAnnouncements.expired)
}

@Test @MainActor func aMomentaryGPSFailureDoesNotStopSharing() async {
    let h = Harness()
    await h.service.start()
    let location = h.location
    await h.run(rounds: 2, [{ location.error = RouteCreationError.locationUnavailable }, { location.error = nil }])
    #expect(h.service.isSharing)
    #expect(h.remote.updates.count == 1)
}

// MARK: Detener

@Test @MainActor func stoppingClosesTheLinkAndSaysSo() async {
    let h = Harness()
    await h.service.start()
    await h.service.stop()
    #expect(h.remote.stops == [h.remote.share.id])
    #expect(h.service.state == .idle)
    #expect(h.spoken.last == LocationSharingAnnouncements.stopped)
}

@Test @MainActor func stoppingOfflineStillStopsHereAndExplainsTheLink() async {
    let h = Harness()
    await h.service.start()
    h.remote.stopError = URLError(.notConnectedToInternet)
    await h.service.stop()
    #expect(h.service.state == .idle)
    #expect(h.spoken.last == LocationSharingAnnouncements.stoppedOffline)
}

@Test @MainActor func signingOutStopsSharing() async {
    let h = Harness()
    await h.service.start()
    await h.service.stopSharing()
    #expect(h.remote.stops.count == 1)
    #expect(!h.service.isSharing)
}

// MARK: Contrato con el backend

@Test func startRequestMatchesTheBackendContract() throws {
    let dto = LocationShareStartDTO(
        position: SharedPosition(latitude: 4.6, longitude: -74.08, accuracyMeters: 9), durationMinutes: 60
    )
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(dto)) as? [String: Any]
    #expect(json?["duration_minutes"] as? Int == 60)
    #expect(json?["accuracy_m"] as? Double == 9)
    #expect(json?["latitude"] as? Double == 4.6)
}

@Test func responseIsDecodedWithBackendDates() throws {
    let data = Data(#"{"id":"6f1c2a52-6d3e-4a8f-9a3a-1b2c3d4e5f60","expires_at":"2026-11-26T15:30:00.123456+00:00","contacts_total":2,"contacts_sent":1}"#.utf8)
    let share = try JSONDecoder().decode(LocationShareReadDTO.self, from: data).share()
    #expect(share.contactsSent == 1)
    #expect(share.expiresAt == BackendDate.parse("2026-11-26T15:30:00.123456+00:00"))
}

@Test func durationsAreSpokenNaturally() {
    #expect(LocationSharingAnnouncements.duration(30) == "30 minutos")
    #expect(LocationSharingAnnouncements.duration(60) == "1 hora")
    #expect(LocationSharingAnnouncements.duration(120) == "2 horas")
}
