import Foundation
import Testing
@testable import LumioFrontend

// MARK: - Cambio correcto

@Test @MainActor func changeKeepsTheRouteAndReplacesItsInstructions() async throws {
    let harness = RouteModificationHarness()
    let previous = harness.storeActiveRoute(currentStep: 1)

    let updated = try await harness.service.changeDestination(to: .query("Parque de los Novios"))

    #expect(updated.id == previous.id)
    #expect(updated.remoteID == previous.remoteID)
    #expect(updated.createdAt == previous.createdAt)
    #expect(updated.destination == park)
    #expect(updated.steps.map(\.instruction) == [
        "Camina hacia el sur por la Calle 19", "El destino está a la derecha",
    ])
    #expect(updated.distanceMeters == 80)
    #expect(updated.currentStep == 0)
    #expect(updated.revision == previous.revision + 1)
    #expect(harness.store.route == updated)
}

@Test @MainActor func changeStartsFromTheCurrentLocation() async throws {
    let harness = RouteModificationHarness()
    harness.storeActiveRoute()
    let moved = GeoCoordinate(latitude: 4.6150, longitude: -74.0700)
    harness.location.result = .success(moved)

    let updated = try await harness.service.changeDestination(to: .query("Parque de los Novios"))

    // Una lectura de GPS nueva: origen, geocodificación y cálculo parten de ella.
    #expect(harness.location.calls == 1)
    #expect(updated.origin == RoutePlace(name: "Ubicación actual", coordinate: moved))
    #expect(harness.geocoder.origins == [moved])
    #expect(harness.calculator.origins.map(\.coordinate) == [moved])
}

@Test @MainActor func changeAnnouncesTheUpdateAndTheFirstNewInstruction() async throws {
    let harness = RouteModificationHarness()
    let previous = harness.storeActiveRoute()

    let updated = try await harness.service.changeDestination(to: .query("Parque de los Novios"))

    #expect(harness.arbiter.received.map(\.text) == [
        "Ruta actualizada hacia Parque de los Novios. Son 80 metros, alrededor de 1 minuto caminando.",
        "Camina hacia el sur por la Calle 19 y continúa 80 metros.",
    ])
    #expect(harness.arbiter.received.allSatisfy { $0.priority == .routeInformation })
    #expect(harness.arbiter.received.allSatisfy {
        $0.contextID == NavigationInstructionBuilder.contextID(for: updated)
    })
    // Las instrucciones anteriores que esperaban turno ya no deben sonar.
    #expect(harness.arbiter.contexts.map(\.invalidatedContextIDs) == [
        [NavigationInstructionBuilder.contextID(for: previous)],
    ])
    #expect(harness.haptics.cues == [.routeReady])
}

@Test @MainActor func selectedSuggestionSkipsGeocoding() async throws {
    let harness = RouteModificationHarness()
    harness.storeActiveRoute()

    let updated = try await harness.service.changeDestination(to: .place(park))

    #expect(harness.geocoder.queries.isEmpty)
    #expect(updated.destination == park)
}

// MARK: - Persistencia en el backend

@Test @MainActor func changeIsPersistedOnTheSameBackendRoute() async throws {
    let harness = RouteModificationHarness()
    let previous = harness.storeActiveRoute()
    let remoteID = try #require(previous.remoteID)

    let updated = try await harness.service.changeDestination(to: .query("Parque de los Novios"))

    #expect(harness.sync.destinationUpdates.map(\.remoteID) == [remoteID])
    #expect(harness.sync.destinationUpdates.first?.route.destination == park)
    #expect(harness.sync.uploads.isEmpty)
    #expect(!updated.isPendingBackendSync)
    #expect(harness.store.route?.hasPendingDestinationChange == false)
}

@Test @MainActor func offlineChangeStaysPendingAndSyncsLater() async throws {
    let harness = RouteModificationHarness()
    harness.storeActiveRoute()
    harness.sync.destinationResult = .failure(URLError(.notConnectedToInternet))

    let updated = try await harness.service.changeDestination(to: .query("Parque de los Novios"))

    // La ruta nueva ya se puede seguir; solo falta avisar al backend.
    #expect(updated.hasPendingDestinationChange)
    #expect(harness.store.route?.destination == park)
    #expect(harness.store.route?.isPendingBackendSync == true)

    harness.sync.destinationResult = .success(())
    let restorer = RouteCreationService(
        location: harness.location, geocoder: harness.geocoder, calculator: harness.calculator,
        store: harness.store, sync: harness.sync, arbiter: harness.arbiter
    )
    let restored = await restorer.restoreActiveRoute()

    #expect(restored?.destination == park)
    #expect(restored?.isPendingBackendSync == false)
    #expect(harness.sync.destinationUpdates.count == 2)
}

@Test @MainActor func routeClosedInTheBackendIsSavedAsNew() async throws {
    let harness = RouteModificationHarness()
    harness.storeActiveRoute()
    harness.sync.destinationResult = .failure(ActiveRouteSyncError.routeNoLongerOpen)
    let newRemoteID = UUID()
    harness.sync.result = .success(newRemoteID)

    let updated = try await harness.service.changeDestination(to: .query("Parque de los Novios"))

    #expect(harness.sync.uploads.map(\.destination) == [park])
    #expect(updated.remoteID == newRemoteID)
    #expect(!updated.isPendingBackendSync)
}

@Test @MainActor func routeNeverSavedInTheBackendIsUploadedComplete() async throws {
    let harness = RouteModificationHarness()
    harness.storeActiveRoute(remoteID: nil)

    let updated = try await harness.service.changeDestination(to: .query("Parque de los Novios"))

    #expect(harness.sync.destinationUpdates.isEmpty)
    #expect(harness.sync.uploads.map(\.destination) == [park])
    #expect(updated.remoteID != nil)
}

@Test @MainActor func slowSyncDoesNotOverwriteANewerChange() async throws {
    let harness = RouteModificationHarness()
    let previous = harness.storeActiveRoute()
    var newer = previous
    newer.revision = 5
    let synchronizer = ActiveRouteSynchronizer(sync: harness.sync, store: harness.store)
    var stale = previous
    stale.revision = 4
    stale.hasPendingDestinationChange = true
    harness.store.route = newer

    _ = await synchronizer.synchronize(stale)

    #expect(harness.store.route == newer)
}

// MARK: - Fallos: la ruta anterior se mantiene

@Test(arguments: [
    RouteCreationError.locationPermissionDenied, .locationUnavailable,
])
@MainActor func locationFailureKeepsThePreviousRoute(error: RouteCreationError) async {
    await expectPreviousRouteKept(after: error) { $0.location.result = .failure(error) }
}

@Test(arguments: [RouteCreationError.destinationNotFound, .serviceUnavailable])
@MainActor func geocodingFailureKeepsThePreviousRoute(error: RouteCreationError) async {
    await expectPreviousRouteKept(after: error) { $0.geocoder.result = .failure(error) }
}

@Test @MainActor func missingWalkingRouteKeepsThePreviousRoute() async {
    await expectPreviousRouteKept(after: .noRouteAvailable) {
        $0.calculator.result = .failure(RouteCreationError.noRouteAvailable)
    }
}

@Test @MainActor func unexpectedProviderErrorIsReportedAsServiceUnavailable() async {
    await expectPreviousRouteKept(after: .serviceUnavailable) {
        $0.calculator.result = .failure(StubError.failed)
    }
}

@Test @MainActor func emptyDestinationIsRejectedBeforeUsingTheGPS() async {
    let harness = await expectPreviousRouteKept(after: .emptyDestination, query: "   ") { _ in }
    #expect(harness.location.calls == 0)
}

@Test @MainActor func sameDestinationIsRejected() async {
    await expectPreviousRouteKept(after: .sameDestination) {
        // A unos 10 m de la farmacia: es el mismo destino.
        $0.geocoder.result = .success(RoutePlace(
            name: "Farmacia Central", coordinate: GeoCoordinate(latitude: 4.61108, longitude: -74.0790)
        ))
    }
}

@Test @MainActor func localStorageFailureKeepsThePreviousRoute() async {
    await expectPreviousRouteKept(after: .localStorageFailed) { $0.store.failSave = true }
}

@Test @MainActor func changeWithoutActiveRouteIsRejected() async {
    let harness = RouteModificationHarness()

    await #expect(throws: RouteCreationError.noActiveRoute) {
        try await harness.service.changeDestination(to: .query("Parque de los Novios"))
    }
    #expect(harness.location.calls == 0)
    #expect(harness.store.route == nil)
    #expect(harness.arbiter.received.map(\.text) == [
        "No hay una ruta activa para cambiar. Indica un destino para crear una.",
    ])
    #expect(harness.haptics.cues == [.routeFailed])
}

/// Comprueba el criterio «si no puede generarse una nueva ruta, se mantiene la anterior
/// y se informa por audio».
@discardableResult
@MainActor private func expectPreviousRouteKept(
    after error: RouteCreationError,
    query: String = "Parque de los Novios",
    arrange: (RouteModificationHarness) -> Void
) async -> RouteModificationHarness {
    let harness = RouteModificationHarness()
    let previous = harness.storeActiveRoute()
    arrange(harness)

    await #expect(throws: error) {
        try await harness.service.changeDestination(to: .query(query))
    }

    #expect(harness.store.route == previous)
    #expect(harness.sync.uploads.isEmpty)
    #expect(harness.sync.destinationUpdates.isEmpty)
    #expect(harness.arbiter.contexts.isEmpty)
    let spoken = harness.arbiter.received.map(\.text)
    #expect(spoken == [RouteAnnouncements.modificationFailure(error, keeping: previous)])
    #expect(spoken.first?.hasSuffix("Sigues con la ruta hacia Farmacia Central.") == true)
    #expect(harness.arbiter.received.first?.priority == .routeInformation)
    #expect(harness.haptics.cues == [.routeFailed])
    return harness
}
