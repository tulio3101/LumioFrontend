import Foundation
import Testing
@testable import LumioFrontend

/// RouteStatusService con dobles: copia local, GPS y árbitro.

@MainActor
private final class UnreadableRouteStore: ActiveRouteStoring {
    func load() throws -> ActiveRoute? { throw StubError.failed }
    func save(_ route: ActiveRoute) throws {}
    func clear() throws {}
}

@MainActor
private struct StatusHarness {
    let store = InMemoryRouteStore()
    let location = FakeLocationProvider()
    let arbiter = SpyArbiter()
    let now = Date(timeIntervalSince1970: 4_000)

    var service: RouteStatusService {
        let fixedNow = now
        return RouteStatusService(store: store, location: location, arbiter: arbiter, now: { fixedNow })
    }

    @discardableResult
    func storeActiveRoute(revision: Int = 0) -> ActiveRoute {
        let route = ActiveRoute(
            id: UUID(),
            remoteID: UUID(),
            origin: RoutePlace(name: "Ubicación actual", coordinate: currentPosition),
            destination: pharmacy,
            steps: NavigationInstructionBuilder().steps(from: sampleCalculatedRoute().steps),
            distanceMeters: 320,
            expectedTravelTimeSeconds: 260,
            createdAt: Date(timeIntervalSince1970: 1_000),
            revision: revision
        )
        store.route = route
        return route
    }
}

@Test @MainActor func activeRouteIsAnsweredFromTheLocalCopy() async throws {
    let harness = StatusHarness()
    let route = harness.storeActiveRoute()

    let status = await harness.service.queryActiveRoute()

    guard case let .active(answered, progress) = status else {
        Issue.record("Se esperaba una ruta activa, llegó \(status)")
        return
    }
    #expect(answered == route)
    #expect(progress.basis == .location)
    #expect(progress.nextStep?.instruction == "Gira a la derecha en la Calle 19")
    #expect(harness.location.calls == 1)

    let message = try #require(harness.arbiter.received.first)
    #expect(harness.arbiter.received.count == 1)
    #expect(message.text == RouteStatusAnnouncements.text(for: status))
    #expect(message.text.hasPrefix("Vas hacia Farmacia Central."))
    #expect(message.contextID == NavigationInstructionBuilder.contextID(for: route))
    #expect(message.createdAt == harness.now)
}

@Test @MainActor func withoutActiveRouteTheAnswerSaysSo() async throws {
    let harness = StatusHarness()

    let status = await harness.service.queryActiveRoute()

    #expect(status == .noActiveRoute)
    #expect(harness.arbiter.received.map(\.text) == [RouteStatusAnnouncements.noActiveRoute])
    // Sin ruta no se pide la ubicación.
    #expect(harness.location.calls == 0)
}

@Test @MainActor func unreadableLocalCopyIsReported() async {
    let arbiter = SpyArbiter()
    let service = RouteStatusService(
        store: UnreadableRouteStore(), location: FakeLocationProvider(), arbiter: arbiter
    )

    #expect(await service.queryActiveRoute() == .unreadable)
    #expect(arbiter.received.map(\.text) == [RouteStatusAnnouncements.unreadable])
}

@Test(arguments: [RouteCreationError.locationPermissionDenied, .locationUnavailable])
@MainActor func withoutLocationTheAnswerIsApproximate(error: RouteCreationError) async throws {
    let harness = StatusHarness()
    harness.storeActiveRoute()
    harness.location.result = .failure(error)

    let status = await harness.service.queryActiveRoute()

    guard case let .active(_, progress) = status else {
        Issue.record("Se esperaba una ruta activa, llegó \(status)")
        return
    }
    #expect(progress.basis == .storedStep)
    let message = try #require(harness.arbiter.received.first)
    #expect(message.text.contains(RouteStatusAnnouncements.approximateNote))
    #expect(message.text.contains("Siguiente indicación: Gira a la derecha en la Calle 19 y continúa 200 metros."))
}

@Test @MainActor func queryDoesNotChangeTheStoredRoute() async {
    let harness = StatusHarness()
    let route = harness.storeActiveRoute()
    harness.location.result = .success(
        GeoCoordinate(latitude: 4.6109, longitude: -74.0800) // Ya pasada la primera maniobra.
    )

    _ = await harness.service.queryActiveRoute()

    #expect(harness.store.route == route)
}

@Test @MainActor func changedRouteIsAnsweredInItsRevisionContext() async throws {
    let harness = StatusHarness()
    let route = harness.storeActiveRoute(revision: 1)

    _ = await harness.service.queryActiveRoute()

    let message = try #require(harness.arbiter.received.first)
    #expect(message.contextID == "route-\(route.id.uuidString)-r1")
}

@Test @MainActor func platformsWithoutNavigationHaveNoActiveRoute() async {
    #expect(await UnavailableNavigationService().queryActiveRoute() == .noActiveRoute)
}
