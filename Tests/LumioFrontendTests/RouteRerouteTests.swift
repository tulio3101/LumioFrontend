import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

/// Recalcular Ruta (SCRUM-26): desviación, servicio de recálculo, monitor, GPS compartido y
/// contrato del backend.

// MARK: - Desviación respecto a la ruta (SCRUM-163)

@Test func pointOnTheRouteIsAtNoDistance() {
    let route = activePharmacyRoute()

    #expect(RouteProgressEstimator.distance(from: currentPosition, to: route) < 1)
    #expect(RouteProgressEstimator.distance(from: pharmacy.coordinate, to: route) < 1)
}

@Test func distanceIsMeasuredToTheNearestSegment() {
    let route = activePharmacyRoute()

    let distance = RouteProgressEstimator.distance(from: fix(offRouteMeters: 60).coordinate, to: route)

    #expect(abs(distance - 60) < 3)
}

@Test func onlyFixesBeyondTheThresholdAreOffRoute() {
    let policy = DeviationPolicy()
    let route = activePharmacyRoute()

    #expect(policy.offRouteThresholdMeters == 30)
    #expect(policy.isOffRoute(fix(offRouteMeters: 10), route: route) == false)
    #expect(policy.isOffRoute(fix(offRouteMeters: 25), route: route) == false)
    #expect(policy.isOffRoute(fix(offRouteMeters: 40), route: route) == true)
    #expect(policy.isOffRoute(fix(offRouteMeters: -60), route: route) == true)
}

@Test func impreciseOrInvalidFixesDoNotDecide() {
    let policy = DeviationPolicy()
    let route = activePharmacyRoute()

    #expect(policy.isOffRoute(fix(offRouteMeters: 60, accuracy: 35), route: route) == nil)
    #expect(policy.isOffRoute(fix(offRouteMeters: 60, accuracy: -1), route: route) == nil)
    let invalid = LocationFix(coordinate: GeoCoordinate(latitude: .nan, longitude: 0), horizontalAccuracy: 5)
    #expect(policy.isOffRoute(invalid, route: route) == nil)
}

@Test func nearTheDestinationIsNeverOffRoute() {
    // Dentro del radio de llegada decide ArrivalMonitor, aunque se esté a un lado del tramo.
    let route = activePharmacyRoute()
    let besideDestination = LocationFix(
        coordinate: GeoCoordinate(latitude: pharmacy.coordinate.latitude + 20 / 111_195, longitude: pharmacy.coordinate.longitude),
        horizontalAccuracy: 5
    )

    #expect(DeviationPolicy(offRouteThresholdMeters: 10).isOffRoute(besideDestination, route: route) == false)
}

// MARK: - Servicio de recálculo (SCRUM-165, 166, 167)

@MainActor
final class HookedRouteCalculator: WalkingRouteCalculating {
    var result: Result<CalculatedRoute, Error> = .success(rerouteCalculatedRoute())
    var onCalculate: (() -> Void)?
    private(set) var destinations: [RoutePlace] = []

    func walkingRoute(from origin: RoutePlace, to destination: RoutePlace) async throws -> CalculatedRoute {
        destinations.append(destination)
        onCalculate?()
        return try result.get()
    }
}

@MainActor
struct RerouteHarness {
    let location = FakeLocationProvider()
    let geocoder = FakeGeocoder()
    let calculator = HookedRouteCalculator()
    let store = InMemoryRouteStore()
    let sync = FakeRouteSync()
    let arbiter = SpyArbiter()
    let haptics = SpyHaptics()
    let connectivity = FakeConnectivity()
    let now = finishNow
    let service: RouteRerouteService

    init() {
        let fixedNow = now
        location.result = .success(deviatedPosition)
        service = RouteRerouteService(
            location: location, geocoder: geocoder, calculator: calculator,
            store: store, sync: sync, arbiter: arbiter, connectivity: connectivity,
            haptics: haptics, now: { fixedNow }
        )
    }

    @discardableResult
    func storeRoute(remoteID: UUID? = UUID(), revision: Int = 0) -> ActiveRoute {
        var route = activePharmacyRoute(remoteID: remoteID, revision: revision)
        route.currentStep = 1
        store.route = route
        return route
    }
}

private func rerouted(_ outcome: RerouteOutcome) -> ActiveRoute? {
    if case .rerouted(let route) = outcome { return route }
    return nil
}

@Test @MainActor func rerouteKeepsRouteAndDestinationAndReplacesThePath() async throws {
    let harness = RerouteHarness()
    let previous = harness.storeRoute()

    let route = try #require(rerouted(await harness.service.reroute(trigger: .deviation)))

    #expect(route.id == previous.id)
    #expect(route.remoteID == previous.remoteID)
    #expect(route.createdAt == previous.createdAt)
    #expect(route.destination == pharmacy)
    #expect(route.origin == RoutePlace(name: "Ubicación actual", coordinate: deviatedPosition))
    #expect(route.steps.map(\.instruction) == [
        "Camina hacia el este por la Calle 17",
        "Gira a la izquierda en la Carrera 5",
        "El destino está a la derecha",
    ])
    #expect(route.distanceMeters == 410)
    #expect(route.currentStep == 0)
    #expect(route.revision == previous.revision + 1)
    #expect(route.reroutedAt == harness.now)
    #expect(harness.store.route == route)
    // El destino ya está ubicado: se calcula hacia él sin volver a geocodificar.
    #expect(harness.calculator.destinations == [pharmacy])
    #expect(harness.geocoder.queries.isEmpty)
}

@Test @MainActor func rerouteAnnouncesTheDeviationTheNewRouteAndItsFirstInstruction() async throws {
    let harness = RerouteHarness()
    let previous = harness.storeRoute()

    let route = try #require(rerouted(await harness.service.reroute(trigger: .deviation)))

    #expect(harness.arbiter.received.map(\.text) == [
        "Te saliste de la ruta. Recalculando.",
        "Ruta recalculada hacia Farmacia Central. Son 410 metros, unos 6 minutos caminando.",
        "Camina hacia el este por la Calle 17 y continúa 150 metros.",
    ])
    #expect(harness.arbiter.received.allSatisfy { $0.priority == .routeInformation })
    #expect(harness.arbiter.received[0].contextID == NavigationInstructionBuilder.rerouteContextID)
    #expect(harness.arbiter.received[1...].allSatisfy {
        $0.contextID == NavigationInstructionBuilder.contextID(for: route)
    })
    // Las instrucciones del recorrido anterior que esperaban turno ya no deben sonar.
    #expect(harness.arbiter.contexts.map(\.invalidatedContextIDs) == [
        [NavigationInstructionBuilder.contextID(for: previous)],
    ])
    #expect(harness.haptics.cues == [.routeReady])
}

@Test @MainActor func eachTriggerHasItsOwnOpeningAnnouncement() async {
    let expected: [(RerouteTrigger, String?)] = [
        (.manual, "Recalculando la ruta."),
        (.reconnected, "Volvió la conexión. Recalculando la ruta."),
        (.retry, nil),
    ]
    for (trigger, text) in expected {
        let harness = RerouteHarness()
        harness.storeRoute()

        _ = await harness.service.reroute(trigger: trigger)

        let first = harness.arbiter.received.first?.text
        if let text {
            #expect(first == text)
        } else {
            #expect(first?.hasPrefix("Ruta recalculada") == true)
        }
    }
}

@Test @MainActor func rerouteIsSyncedWithTheBackendRerouteEndpoint() async throws {
    let harness = RerouteHarness()
    let previous = harness.storeRoute()

    let route = try #require(rerouted(await harness.service.reroute(trigger: .deviation)))

    #expect(harness.sync.reroutes.count == 1)
    #expect(harness.sync.reroutes.first?.remoteID == previous.remoteID)
    #expect(harness.sync.reroutes.first?.reroutedAt == harness.now)
    #expect(harness.sync.uploads.isEmpty)
    #expect(harness.sync.destinationUpdates.isEmpty)
    #expect(!route.isPendingBackendSync)
    #expect(harness.store.route?.hasPendingReroute == false)
}

@Test @MainActor func rerouteStaysPendingWhenTheBackendFails() async throws {
    let harness = RerouteHarness()
    harness.storeRoute()
    harness.sync.rerouteResult = .failure(StubError.failed)

    let route = try #require(rerouted(await harness.service.reroute(trigger: .deviation)))

    // La guía no depende del backend: la ruta nueva ya es la activa y queda pendiente.
    #expect(route.hasPendingReroute)
    #expect(harness.store.route == route)
    #expect(harness.arbiter.received.contains { $0.text.hasPrefix("Ruta recalculada") })
}

@Test @MainActor func routeNotYetInTheBackendIsUploadedWhole() async throws {
    let harness = RerouteHarness()
    harness.storeRoute(remoteID: nil)

    let route = try #require(rerouted(await harness.service.reroute(trigger: .deviation)))

    #expect(harness.sync.uploads.map(\.steps) == [route.steps])
    #expect(harness.sync.reroutes.isEmpty)
    #expect(route.remoteID != nil)
}

@Test @MainActor func rejectedRerouteFallsBackToReplacingTheWholeRoute() async throws {
    let harness = RerouteHarness()
    harness.storeRoute()
    harness.sync.rerouteResult = .failure(ActiveRouteSyncError.rerouteRejected)

    let route = try #require(rerouted(await harness.service.reroute(trigger: .deviation)))

    #expect(harness.sync.destinationUpdates.map(\.route.steps) == [route.steps])
    #expect(!route.isPendingBackendSync)
}

@Test @MainActor func withoutConnectionTheRouteIsKeptAndItSaysSo() async {
    let harness = RerouteHarness()
    let previous = harness.storeRoute()
    harness.connectivity.isConnected = false

    let outcome = await harness.service.reroute(trigger: .deviation)

    #expect(outcome == .offline)
    #expect(harness.calculator.destinations.isEmpty)
    #expect(harness.location.calls == 0)
    #expect(harness.store.route == previous)
    #expect(harness.arbiter.received.map(\.text) == [
        "Sin conexión: no se puede recalcular la ruta. Sigue las indicaciones de tu ruta hacia "
            + "Farmacia Central. Se recalculará cuando vuelva la conexión.",
    ])
    #expect(harness.arbiter.contexts.isEmpty)
}

@Test @MainActor func offlineRetryIsSilent() async {
    let harness = RerouteHarness()
    harness.storeRoute()
    harness.connectivity.isConnected = false

    #expect(await harness.service.reroute(trigger: .retry) == .offline)
    #expect(harness.arbiter.received.isEmpty)
}

@Test @MainActor func failedRerouteKeepsThePreviousRouteAndSaysSo() async {
    let harness = RerouteHarness()
    let previous = harness.storeRoute()
    harness.calculator.result = .failure(RouteCreationError.noRouteAvailable)

    let outcome = await harness.service.reroute(trigger: .deviation)

    #expect(outcome == .failed(.noRouteAvailable))
    #expect(harness.store.route == previous)
    #expect(harness.arbiter.received.map(\.text) == [
        "Te saliste de la ruta. Recalculando.",
        "No se pudo recalcular la ruta. No hay una ruta peatonal disponible hacia ese destino. "
            + "Sigues con la ruta hacia Farmacia Central.",
    ])
    #expect(harness.arbiter.contexts.isEmpty)
    #expect(harness.haptics.cues == [.routeFailed])
    #expect(harness.sync.reroutes.isEmpty)
}

@Test @MainActor func failedRetryIsSilent() async {
    let harness = RerouteHarness()
    harness.storeRoute()
    harness.location.result = .failure(RouteCreationError.locationUnavailable)

    #expect(await harness.service.reroute(trigger: .retry) == .failed(.locationUnavailable))
    #expect(harness.arbiter.received.isEmpty)
    #expect(harness.haptics.cues.isEmpty)
}

@Test @MainActor func unexpectedRerouteErrorsAreReportedAsServiceUnavailable() async {
    let harness = RerouteHarness()
    harness.storeRoute()
    harness.calculator.result = .failure(StubError.failed)

    #expect(await harness.service.reroute(trigger: .manual) == .failed(.serviceUnavailable))
}

@Test @MainActor func rerouteLocalStorageFailureKeepsThePreviousRoute() async {
    let harness = RerouteHarness()
    let previous = harness.storeRoute()
    harness.store.failSave = true

    #expect(await harness.service.reroute(trigger: .deviation) == .failed(.localStorageFailed))
    #expect(harness.store.route == previous)
}

@Test @MainActor func routeChangedWhileCalculatingIsNotOverwritten() async {
    let harness = RerouteHarness()
    harness.storeRoute()
    var changed = activePharmacyRoute(revision: 3)
    changed.currentStep = 0
    harness.calculator.onCalculate = { harness.store.route = changed }

    #expect(await harness.service.reroute(trigger: .deviation) == .superseded)
    #expect(harness.store.route == changed)
    #expect(harness.arbiter.contexts.isEmpty)
    #expect(harness.sync.reroutes.isEmpty)
}

@Test @MainActor func routeFinishedWhileCalculatingIsNotRestored() async {
    let harness = RerouteHarness()
    harness.storeRoute()
    harness.calculator.onCalculate = { harness.store.route = nil }

    #expect(await harness.service.reroute(trigger: .deviation) == .superseded)
    #expect(harness.store.route == nil)
}

@Test @MainActor func manualRerouteWithoutRouteSaysThereIsNone() async {
    let harness = RerouteHarness()

    #expect(await harness.service.reroute(trigger: .manual) == .noActiveRoute)
    #expect(harness.arbiter.received.map(\.text) == ["No hay una ruta activa para recalcular."])
}

// MARK: - Monitor de desviación (SCRUM-163, 164)

@MainActor
final class FakeRerouter: RouteRerouting {
    /// Resultados en orden; al agotarse, `.failed(.serviceUnavailable)`.
    var outcomes: [RerouteOutcome] = []
    private(set) var triggers: [RerouteTrigger] = []

    func reroute(trigger: RerouteTrigger) async -> RerouteOutcome {
        triggers.append(trigger)
        return outcomes.isEmpty ? .failed(.serviceUnavailable) : outcomes.removeFirst()
    }
}

@MainActor
final class DeviationHarness {
    let tracker = FakeLocationTracker()
    let store = InMemoryRouteStore()
    let rerouter = FakeRerouter()
    let connectivity = FakeConnectivity()
    var clock = finishNow
    private(set) var statuses: [RerouteStatus?] = []
    private(set) var monitor: RouteDeviationMonitor!

    init(route: ActiveRoute? = activePharmacyRoute()) {
        store.route = route
        monitor = RouteDeviationMonitor(
            tracker: tracker, store: store, rerouter: rerouter, connectivity: connectivity,
            now: { [unowned self] in self.clock }
        )
        monitor.onStatusChange = { [unowned self] in self.statuses.append($0) }
    }

    func deviate(fixes: Int = 3) async {
        for _ in 0..<fixes { await monitor.handle(fix(offRouteMeters: 60)) }
    }

    func advance(seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    /// El recálculo correcto: misma ruta, revisión siguiente.
    func reroutedRoute() -> ActiveRoute {
        var route = store.route!
        route.revision += 1
        return route
    }
}

@Test @MainActor func threePreciseOffRouteFixesTriggerTheReroute() async {
    let harness = DeviationHarness()
    harness.monitor.startMonitoring()

    await harness.deviate(fixes: 2)
    #expect(harness.rerouter.triggers.isEmpty)
    await harness.deviate(fixes: 1)

    #expect(harness.rerouter.triggers == [.deviation])
    #expect(harness.tracker.starts == 1)
}

@Test @MainActor func impreciseFixesNeitherCountNorReset() async {
    let harness = DeviationHarness()
    harness.monitor.startMonitoring()

    await harness.deviate(fixes: 2)
    await harness.monitor.handle(fix(offRouteMeters: 0, accuracy: 50))
    #expect(harness.rerouter.triggers.isEmpty)
    await harness.deviate(fixes: 1)

    #expect(harness.rerouter.triggers == [.deviation])
}

@Test @MainActor func aPreciseFixOnTheRouteResetsTheCount() async {
    let harness = DeviationHarness()
    harness.monitor.startMonitoring()

    await harness.deviate(fixes: 2)
    await harness.monitor.handle(fix(offRouteMeters: 5))
    await harness.deviate(fixes: 2)

    #expect(harness.rerouter.triggers.isEmpty)
}

@Test @MainActor func failedRerouteIsRetriedOnlyAfterTheCooldown() async {
    let harness = DeviationHarness()
    harness.monitor.startMonitoring()

    await harness.deviate()
    harness.advance(seconds: 10)
    await harness.deviate(fixes: 1)
    #expect(harness.rerouter.triggers == [.deviation])

    harness.advance(seconds: 10)
    await harness.deviate(fixes: 1)
    // El reintento no repite «Te saliste de la ruta» ni el fallo.
    #expect(harness.rerouter.triggers == [.deviation, .retry])
}

@Test @MainActor func afterThreeFailuresItStopsUntilBackOnTheRoute() async {
    let harness = DeviationHarness()
    harness.monitor.startMonitoring()

    await harness.deviate()
    for _ in 0..<3 {
        harness.advance(seconds: 21)
        await harness.deviate(fixes: 1)
    }
    #expect(harness.rerouter.triggers == [.deviation, .retry, .retry])
    #expect(harness.statuses.last == .failed(.serviceUnavailable, destination: "Farmacia Central", retry: .stopped))

    // De vuelta en el trayecto se borra el aviso; una nueva desviación empieza de cero.
    await harness.monitor.handle(fix(offRouteMeters: 5))
    #expect(harness.statuses.last == .some(nil))
    harness.advance(seconds: 21)
    await harness.deviate()
    #expect(harness.rerouter.triggers == [.deviation, .retry, .retry, .deviation])
}

@Test @MainActor func failureStatusSaysWhetherItWillRetry() async {
    let harness = DeviationHarness()
    harness.rerouter.outcomes = [.failed(.noRouteAvailable)]
    harness.monitor.startMonitoring()

    await harness.deviate()

    #expect(harness.statuses == [
        .rerouting,
        .failed(.noRouteAvailable, destination: "Farmacia Central", retry: .automatic),
    ])
}

@Test @MainActor func successfulRerouteResetsTheDeviation() async {
    let harness = DeviationHarness()
    let rerouted = harness.reroutedRoute()
    harness.rerouter.outcomes = [.rerouted(rerouted)]
    harness.monitor.startMonitoring()

    await harness.deviate()
    harness.store.route = rerouted
    #expect(harness.statuses == [.rerouting, .rerouted(rerouted)])

    // Contra el recorrido nuevo, la cuenta empieza de cero y se respeta la espera.
    harness.advance(seconds: 5)
    await harness.deviate()
    #expect(harness.rerouter.triggers == [.deviation])
    harness.advance(seconds: 20)
    await harness.deviate(fixes: 1)
    #expect(harness.rerouter.triggers == [.deviation, .deviation])
}

@Test @MainActor func reroutedConfirmationStaysWhileFollowingTheNewRoute() async {
    let harness = DeviationHarness()
    let rerouted = harness.reroutedRoute()
    harness.rerouter.outcomes = [.rerouted(rerouted)]
    harness.monitor.startMonitoring()
    await harness.deviate()
    harness.store.route = rerouted

    await harness.monitor.handle(fix(offRouteMeters: 5))

    #expect(harness.statuses.last == .rerouted(rerouted))
}

@Test @MainActor func withoutConnectionItWaitsAndRetriesWhenItReturns() async {
    let harness = DeviationHarness()
    harness.rerouter.outcomes = [.offline]
    harness.monitor.startMonitoring()
    harness.connectivity.isConnected = false

    await harness.deviate()
    #expect(harness.statuses.last == .waitingForConnection(destination: "Farmacia Central"))
    // Mientras no hay red no se insiste (ni se repite el aviso).
    harness.advance(seconds: 60)
    await harness.deviate(fixes: 2)
    #expect(harness.rerouter.triggers == [.deviation])

    harness.connectivity.isConnected = true
    await harness.monitor.connectionRestored()

    #expect(harness.rerouter.triggers == [.deviation, .reconnected])
    #expect(harness.connectivity.handlers.count == 1)
}

@Test @MainActor func aMissedReconnectionIsNoticedOnTheNextFix() async {
    let harness = DeviationHarness()
    harness.rerouter.outcomes = [.offline]
    harness.monitor.startMonitoring()

    await harness.deviate()
    harness.connectivity.isConnected = true
    await harness.deviate(fixes: 1)

    #expect(harness.rerouter.triggers == [.deviation, .reconnected])
}

@Test @MainActor func reconnectionAfterReturningToTheRouteDoesNothing() async {
    let harness = DeviationHarness()
    harness.rerouter.outcomes = [.offline]
    harness.monitor.startMonitoring()

    await harness.deviate()
    await harness.monitor.handle(fix(offRouteMeters: 5))
    await harness.monitor.connectionRestored()

    #expect(harness.rerouter.triggers == [.deviation])
    #expect(harness.statuses.last == .some(nil))
}

@Test @MainActor func manualRerouteIgnoresCooldownAndFailureLimit() async {
    let harness = DeviationHarness()
    harness.monitor.startMonitoring()
    await harness.deviate()

    let outcome = await harness.monitor.rerouteNow()

    #expect(outcome == .failed(.serviceUnavailable))
    #expect(harness.rerouter.triggers == [.deviation, .manual])
}

@Test @MainActor func manualFailureWhileOnTheRouteHasNoAutomaticRetry() async {
    let harness = DeviationHarness()
    harness.monitor.startMonitoring()

    await harness.monitor.rerouteNow()

    #expect(harness.statuses.last == .failed(.serviceUnavailable, destination: "Farmacia Central", retry: .none))
}

@Test @MainActor func monitoringNeedsAnActiveRoute() async {
    let harness = DeviationHarness(route: nil)

    harness.monitor.startMonitoring()
    await harness.monitor.handle(fix(offRouteMeters: 60))

    #expect(harness.tracker.starts == 0)
    #expect(harness.rerouter.triggers.isEmpty)
}

@Test @MainActor func monitoringStopsWhenTheRouteEnds() async {
    let harness = DeviationHarness()
    harness.monitor.startMonitoring()
    harness.store.route = nil

    await harness.monitor.handle(fix(offRouteMeters: 60))

    #expect(harness.tracker.stops == 1)
    await harness.deviate()
    #expect(harness.rerouter.triggers.isEmpty)
}

@Test @MainActor func anotherDestinationRestartsTheCount() async {
    let harness = DeviationHarness()
    harness.monitor.startMonitoring()

    await harness.deviate(fixes: 2)
    harness.store.route = activePharmacyRoute(revision: 1)
    await harness.deviate(fixes: 2)

    #expect(harness.rerouter.triggers.isEmpty)
}

@Test @MainActor func defaultPolicyMatchesTheTeamAgreement() {
    let policy = DeviationPolicy()

    #expect(policy.offRouteThresholdMeters == 30)
    #expect(policy.maximumAccuracyMeters == 20)
    #expect(policy.requiredConsecutiveFixes == 3)
    #expect(policy.cooldownSeconds == 20)
    #expect(policy.maximumConsecutiveFailures == 3)
}

// MARK: - Estado en pantalla

@Test func screenStatusUsesTheSpokenTexts() {
    let route = activePharmacyRoute()

    #expect(RerouteStatus.rerouting.message == "Recalculando la ruta…")
    #expect(RerouteStatus.rerouted(route).message
        == "Ruta recalculada hacia Farmacia Central. Son 320 metros, unos 4 minutos caminando.")
    #expect(RerouteStatus.waitingForConnection(destination: "Farmacia Central").message
        == RerouteAnnouncements.offline(destination: "Farmacia Central"))
    let failure = RerouteAnnouncements.failure(.locationUnavailable, destination: "Farmacia Central")
    #expect(RerouteStatus.failed(.locationUnavailable, destination: "Farmacia Central", retry: .automatic).message == failure)
    #expect(RerouteStatus.failed(.locationUnavailable, destination: "Farmacia Central", retry: .stopped).message
        == failure + " " + RerouteAnnouncements.gaveUpHint)
    #expect(RerouteAnnouncements.failure(.serviceUnavailable, destination: nil) == RerouteAnnouncements.noActiveRoute)
}

// MARK: - GPS compartido

@Test @MainActor func sharedTrackerRunsWhileAnyClientNeedsIt() {
    let base = FakeLocationTracker()
    let shared = SharedLocationTracker(base: base)
    let arrival = shared.makeClient()
    let deviation = shared.makeClient()

    arrival.start()
    deviation.start()
    arrival.start()
    #expect(base.starts == 1)

    arrival.stop()
    #expect(base.stops == 0)
    deviation.stop()
    #expect(base.stops == 1)
}

@Test @MainActor func sharedTrackerSendsFixesOnlyToRunningClients() {
    let base = FakeLocationTracker()
    let shared = SharedLocationTracker(base: base)
    let arrival = shared.makeClient()
    let deviation = shared.makeClient()
    var arrivalFixes = 0
    var deviationFixes = 0
    arrival.onFix = { _ in arrivalFixes += 1 }
    deviation.onFix = { _ in deviationFixes += 1 }

    arrival.start()
    base.onFix?(fix(offRouteMeters: 0))
    deviation.start()
    base.onFix?(fix(offRouteMeters: 0))

    #expect(arrivalFixes == 2)
    #expect(deviationFixes == 1)
}

// MARK: - Contrato del backend (SCRUM-168)

@Test func rerouteBodyIsTheRouteWithItsRerouteTime() throws {
    let route = activePharmacyRoute()

    let data = try JSONEncoder().encode(RouteRerouteDTO(route, reroutedAt: finishNow))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(json["rerouted_at"] as? String == BackendDate.string(from: finishNow))
    #expect((json["destination"] as? [String: Any])?["name"] as? String == "Farmacia Central")
    #expect((json["steps"] as? [[String: Any]])?.count == route.steps.count)
    #expect(json["distance_meters"] as? Double == 320)
}

@Test @MainActor func remoteRerouteUsesTheRerouteEndpoint() async throws {
    let http = FakeHTTPClient(response: .success(integrationBackendResponse))
    let service = RemoteActiveRouteService(client: http, baseURL: URL(string: "http://localhost:8000")!)
    let remoteID = UUID()

    try await service.reroute(activePharmacyRoute(), remoteID: remoteID, reroutedAt: finishNow)

    let request = try #require(http.requests.first)
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.path == "/places/routes/\(remoteID.uuidString.lowercased())/reroute")
}

@Test @MainActor func remoteRerouteMapsTheBackendErrors() async {
    let http = FakeHTTPClient(response: .failure(HTTPClientError.statusCode(404)))
    let service = RemoteActiveRouteService(client: http, baseURL: URL(string: "http://localhost:8000")!)

    await #expect(throws: ActiveRouteSyncError.routeNoLongerOpen) {
        try await service.reroute(activePharmacyRoute(), remoteID: UUID(), reroutedAt: finishNow)
    }
    http.response = .failure(HTTPClientError.statusCode(409))
    await #expect(throws: ActiveRouteSyncError.rerouteRejected) {
        try await service.reroute(activePharmacyRoute(), remoteID: UUID(), reroutedAt: finishNow)
    }
}

// MARK: - Copia local y sincronización

@Test func localCopiesSavedBeforeRerouteAreStillRead() throws {
    var route = activePharmacyRoute()
    route.hasPendingReroute = true
    route.reroutedAt = finishNow
    let data = try JSONEncoder().encode(route)
    var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    json.removeValue(forKey: "hasPendingReroute")
    json.removeValue(forKey: "reroutedAt")

    let decoded = try JSONDecoder().decode(ActiveRoute.self, from: JSONSerialization.data(withJSONObject: json))

    #expect(!decoded.hasPendingReroute)
    #expect(decoded.reroutedAt == nil)
    #expect(decoded.id == route.id)
}

@Test @MainActor func pendingRerouteIsSentWhenTheRouteIsRestored() async throws {
    let store = InMemoryRouteStore()
    let sync = FakeRouteSync()
    var route = activePharmacyRoute(revision: 1)
    route.hasPendingReroute = true
    route.reroutedAt = finishNow
    store.route = route

    let synced = await ActiveRouteSynchronizer(sync: sync, store: store).synchronize(route)

    #expect(sync.reroutes.map(\.reroutedAt) == [finishNow])
    #expect(!synced.isPendingBackendSync)
    #expect(store.route?.hasPendingReroute == false)
}

@Test @MainActor func pendingDestinationChangeWinsOverPendingReroute() async {
    let sync = FakeRouteSync()
    var route = activePharmacyRoute(pendingChange: true)
    route.hasPendingReroute = true

    try? await sync.pushPendingChanges(of: route, remoteID: route.remoteID!)

    // El cambio de destino ya envía el recorrido completo.
    #expect(sync.destinationUpdates.count == 1)
    #expect(sync.reroutes.isEmpty)
}

@Test @MainActor func routeClosedInTheBackendIsUploadedAgain() async {
    let store = InMemoryRouteStore()
    let sync = FakeRouteSync()
    sync.rerouteResult = .failure(ActiveRouteSyncError.routeNoLongerOpen)
    var route = activePharmacyRoute(revision: 1)
    route.hasPendingReroute = true
    store.route = route

    let synced = await ActiveRouteSynchronizer(sync: sync, store: store).synchronize(route)

    #expect(sync.uploads.count == 1)
    #expect(!synced.isPendingBackendSync)
}

@Test @MainActor func finishedRouteSendsItsPendingRerouteFirst() async {
    let routes = InMemoryFinishedRoutesStore()
    let finishSync = FakeFinishedRouteSync()
    let routeSync = FakeRouteSync()
    var route = activePharmacyRoute(revision: 1)
    route.hasPendingReroute = true
    route.reroutedAt = finishNow
    routes.routes = [FinishedRoute(route: route, outcome: .completed, finishedAt: finishNow)]
    let history = FinishedRouteSynchronizer(store: routes, finishSync: finishSync, routeSync: routeSync)

    #expect(await history.flush())

    #expect(routeSync.reroutes.count == 1)
    #expect(finishSync.calls == ["finish"])
}
