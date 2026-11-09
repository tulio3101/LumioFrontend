import Foundation
import Testing
@testable import LumioFrontend

@Test @MainActor func routeGoesFromCurrentLocationToGeocodedDestination() async throws {
    let harness = RouteCreationHarness()

    let route = try await harness.service.createRoute(to: .query("  Farmacia Central \n"))

    #expect(harness.location.calls == 1)
    #expect(harness.geocoder.queries == ["Farmacia Central"])
    #expect(harness.geocoder.origins == [currentPosition])
    #expect(route.origin == RoutePlace(name: "Ubicación actual", coordinate: currentPosition))
    #expect(route.destination == pharmacy)
    #expect(harness.calculator.origins == [route.origin])
    #expect(harness.calculator.destinations == [pharmacy])
    #expect(route.distanceMeters == 320)
    #expect(route.expectedTravelTimeSeconds == 260)
    #expect(route.currentStep == 0)
    #expect(route.createdAt == harness.now)
}

@Test @MainActor func routeContainsStepByStepInstructions() async throws {
    let harness = RouteCreationHarness()

    let route = try await harness.service.createRoute(to: .query("Farmacia Central"))

    #expect(route.steps.map(\.order) == [0, 1])
    #expect(route.steps.first?.instruction == "Gira a la derecha en la Calle 19")
}

@Test @MainActor func readyRouteIsAnnouncedWithItsFirstInstruction() async throws {
    let routeID = UUID()
    let harness = RouteCreationHarness(routeIDs: [routeID])

    _ = try await harness.service.createRoute(to: .query("Farmacia Central"))

    let messages = harness.arbiter.received
    #expect(messages.map(\.text) == [
        "Ruta lista hacia Farmacia Central. Son 320 metros, unos 4 minutos caminando.",
        "Gira a la derecha en la Calle 19 y continúa 200 metros.",
    ])
    #expect(messages.allSatisfy { $0.priority == .routeInformation })
    #expect(messages.allSatisfy { $0.contextID == "route-\(routeID.uuidString)" })
    #expect(harness.haptics.cues == [.routeReady])
}

@Test @MainActor func routeIsSavedLocallyAndPersistedInBackend() async throws {
    let harness = RouteCreationHarness()
    let backendID = UUID()
    harness.sync.result = .success(backendID)

    let route = try await harness.service.createRoute(to: .query("Farmacia Central"))

    #expect(route.remoteID == backendID)
    #expect(!route.isPendingBackendSync)
    #expect(harness.store.route == route)
    #expect(harness.sync.uploads.count == 1)
    #expect(harness.sync.uploads.first?.steps == route.steps)
}

@Test @MainActor func backendFailureKeepsTheRouteReadyAndPending() async throws {
    let harness = RouteCreationHarness()
    harness.sync.result = .failure(StubError.failed)

    let route = try await harness.service.createRoute(to: .query("Farmacia Central"))

    #expect(route.isPendingBackendSync)
    #expect(harness.store.route == route)
    #expect(harness.arbiter.received.count == 2)
    #expect(harness.haptics.cues == [.routeReady])
}

@Test @MainActor func restoreRetriesPendingBackendPersistence() async throws {
    let harness = RouteCreationHarness()
    harness.sync.result = .failure(StubError.failed)
    let pending = try await harness.service.createRoute(to: .query("Farmacia Central"))
    let backendID = UUID()
    harness.sync.result = .success(backendID)

    let restored = await harness.service.restoreActiveRoute()

    #expect(restored?.id == pending.id)
    #expect(restored?.remoteID == backendID)
    #expect(harness.store.route?.remoteID == backendID)
}

@Test @MainActor func restoreDoesNotUploadARouteAlreadyInBackend() async throws {
    let harness = RouteCreationHarness()
    let route = try await harness.service.createRoute(to: .query("Farmacia Central"))

    let restored = await harness.service.restoreActiveRoute()

    #expect(restored == route)
    #expect(harness.sync.uploads.count == 1)
}

@Test @MainActor func restoreWithoutLocalCopyHasNoRoute() async {
    let harness = RouteCreationHarness()

    #expect(await harness.service.restoreActiveRoute() == nil)
    #expect(harness.sync.uploads.isEmpty)
}

@Test @MainActor func unavailableRouteIsAnnouncedAndNothingIsSaved() async {
    let harness = RouteCreationHarness()
    harness.calculator.result = .failure(RouteCreationError.noRouteAvailable)

    await #expect(throws: RouteCreationError.noRouteAvailable) {
        try await harness.service.createRoute(to: .query("Isla lejana"))
    }

    #expect(harness.arbiter.received.map(\.text) == [
        "No hay una ruta peatonal disponible hacia ese destino.",
    ])
    #expect(harness.arbiter.received.first?.priority == .routeInformation)
    #expect(harness.haptics.cues == [.routeFailed])
    #expect(harness.store.route == nil)
    #expect(harness.sync.uploads.isEmpty)
}

@Test @MainActor func routeWithoutUsableInstructionsIsUnavailable() async {
    let harness = RouteCreationHarness()
    harness.calculator.result = .success(CalculatedRoute(
        distanceMeters: 50, expectedTravelTimeSeconds: 40,
        steps: [CalculatedRouteStep(instruction: " ", distanceMeters: 50, maneuverCoordinate: nil)]
    ))

    await #expect(throws: RouteCreationError.noRouteAvailable) {
        try await harness.service.createRoute(to: .query("Farmacia Central"))
    }
}

@Test(arguments: [
    RouteCreationError.locationPermissionDenied, .locationUnavailable,
])
@MainActor func locationFailuresStopBeforeGeocoding(error: RouteCreationError) async {
    let harness = RouteCreationHarness()
    harness.location.result = .failure(error)

    await #expect(throws: error) {
        try await harness.service.createRoute(to: .query("Farmacia Central"))
    }

    #expect(harness.geocoder.queries.isEmpty)
    #expect(harness.arbiter.received.map(\.text) == [RouteAnnouncements.failure(error)])
}

@Test(arguments: [RouteCreationError.destinationNotFound, .serviceUnavailable])
@MainActor func geocodingFailuresAreAnnounced(error: RouteCreationError) async {
    let harness = RouteCreationHarness()
    harness.geocoder.result = .failure(error)

    await #expect(throws: error) {
        try await harness.service.createRoute(to: .query("Lugar inexistente"))
    }

    #expect(harness.calculator.destinations.isEmpty)
    #expect(harness.arbiter.received.map(\.text) == [RouteAnnouncements.failure(error)])
}

@Test @MainActor func unexpectedErrorsAreReportedAsServiceUnavailable() async {
    let harness = RouteCreationHarness()
    harness.calculator.result = .failure(StubError.failed)

    await #expect(throws: RouteCreationError.serviceUnavailable) {
        try await harness.service.createRoute(to: .query("Farmacia Central"))
    }
}

@Test @MainActor func emptyDestinationIsRejectedBeforeLocating() async {
    let harness = RouteCreationHarness()

    await #expect(throws: RouteCreationError.emptyDestination) {
        try await harness.service.createRoute(to: .query("   "))
    }

    #expect(harness.location.calls == 0)
    #expect(harness.arbiter.received.count == 1)
}

@Test @MainActor func confirmedPlaceSkipsGeocoding() async throws {
    let harness = RouteCreationHarness()

    let route = try await harness.service.createRoute(to: .place(pharmacy))

    #expect(harness.geocoder.queries.isEmpty)
    #expect(route.destination == pharmacy)
}

@Test @MainActor func localStorageFailureIsAnnouncedAndNotUploaded() async {
    let harness = RouteCreationHarness()
    harness.store.failSave = true

    await #expect(throws: RouteCreationError.localStorageFailed) {
        try await harness.service.createRoute(to: .query("Farmacia Central"))
    }

    #expect(harness.sync.uploads.isEmpty)
    #expect(harness.haptics.cues == [.routeFailed])
}

@Test @MainActor func newRouteInvalidatesPendingMessagesOfThePreviousOne() async throws {
    let harness = RouteCreationHarness(routeIDs: [UUID(), UUID()])
    let first = try await harness.service.createRoute(to: .query("Farmacia Central"))
    #expect(harness.arbiter.contexts.isEmpty)

    let second = try await harness.service.createRoute(to: .query("Parque"))

    #expect(harness.store.route?.id == second.id)
    #expect(harness.arbiter.contexts.last?.invalidatedContextIDs == [
        NavigationInstructionBuilder.contextID(for: first),
    ])
}
