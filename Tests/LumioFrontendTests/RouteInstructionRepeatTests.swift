import Foundation
import Testing
@testable import LumioFrontend

/// Repetir la indicación actual: botón «Repetir indicación» y Magic Tap en «Tu ruta».

private func pharmacyRoute(currentStep: Int = 0, revision: Int = 0, steps: [RouteStep]? = nil) -> ActiveRoute {
    ActiveRoute(
        id: UUID(),
        remoteID: UUID(),
        origin: RoutePlace(name: "Ubicación actual", coordinate: currentPosition),
        destination: pharmacy,
        steps: steps ?? NavigationInstructionBuilder().steps(from: sampleCalculatedRoute().steps),
        distanceMeters: 320,
        expectedTravelTimeSeconds: 260,
        createdAt: Date(timeIntervalSince1970: 1_000),
        currentStep: currentStep,
        revision: revision
    )
}

// MARK: - Indicación actual

@Test func currentInstructionFollowsTheCurrentStep() {
    #expect(pharmacyRoute(currentStep: 0).currentInstruction?.instruction == "Gira a la derecha en la Calle 19")
    #expect(pharmacyRoute(currentStep: 1).currentInstruction?.instruction == "El destino está a la izquierda")
}

@Test func currentInstructionPastTheLastStepIsTheArrival() {
    #expect(pharmacyRoute(currentStep: 7).currentInstruction?.instruction == "El destino está a la izquierda")
}

@Test func routeWithoutStepsHasNoCurrentInstruction() {
    #expect(pharmacyRoute(steps: []).currentInstruction == nil)
}

// MARK: - Repetidor

@Test @MainActor func repeatSpeaksTheCurrentStepAsRouteInformation() throws {
    let arbiter = SpyArbiter()
    let now = Date(timeIntervalSince1970: 3_000)
    let repeater = RouteInstructionRepeater(arbiter: arbiter, now: { now })
    let route = pharmacyRoute(currentStep: 0)

    #expect(repeater.repeatCurrentInstruction(of: route))

    let message = try #require(arbiter.received.first)
    #expect(arbiter.received.count == 1)
    #expect(message.text == "Gira a la derecha en la Calle 19 y continúa 200 metros.")
    #expect(message.priority == .routeInformation)
    #expect(message.createdAt == now)
    // Mismo evento que el anuncio original: mismo contexto y misma clave del paso.
    #expect(message.contextID == NavigationInstructionBuilder.contextID(for: route))
    #expect(message.deduplicationKey == "step-0")
}

@Test @MainActor func repeatUsesTheRevisionOfTheChangedRoute() throws {
    let arbiter = SpyArbiter()
    let repeater = RouteInstructionRepeater(arbiter: arbiter)
    let route = pharmacyRoute(currentStep: 1, revision: 2)

    repeater.repeatCurrentInstruction(of: route)

    let message = try #require(arbiter.received.first)
    #expect(message.text == "El destino está a la izquierda.")
    #expect(message.contextID == "route-\(route.id.uuidString)-r2")
    #expect(message.deduplicationKey == "step-1")
}

@Test @MainActor func repeatWithoutInstructionsSaysNothing() {
    let arbiter = SpyArbiter()
    let repeater = RouteInstructionRepeater(arbiter: arbiter)

    #expect(!repeater.repeatCurrentInstruction(of: pharmacyRoute(steps: [])))
    #expect(arbiter.received.isEmpty)
}

@Test @MainActor func platformsWithoutNavigationCannotRepeat() {
    #expect(!UnavailableNavigationService().repeatCurrentInstruction(of: pharmacyRoute()))
}

// MARK: - Con el AudioArbiter real

@Test @MainActor func repeatIsNotDuplicatedWhileTheInstructionIsStillPending() async throws {
    let flow = IntegratedFlow(backend: .success(integrationBackendResponse))
    defer { flow.cleanUp() }
    let route = try await flow.service.createRoute(to: .query("Farmacia Central"))
    let repeater = RouteInstructionRepeater(arbiter: flow.arbiter)

    // «Ruta lista» suena y la primera instrucción espera turno: repetirla no la duplica.
    repeater.repeatCurrentInstruction(of: route)

    #expect(flow.arbiter.pendingMessages.map(\.text) == ["Gira a la derecha en la Calle 19 y continúa 200 metros."])
}

@Test @MainActor func repeatPlaysAgainOnceTheInstructionWasHeard() async throws {
    let flow = IntegratedFlow(backend: .success(integrationBackendResponse))
    defer { flow.cleanUp() }
    let route = try await flow.service.createRoute(to: .query("Farmacia Central"))
    flow.player.finish()
    flow.player.finish()
    #expect(flow.arbiter.currentMessage == nil)

    RouteInstructionRepeater(arbiter: flow.arbiter).repeatCurrentInstruction(of: route)

    #expect(flow.arbiter.currentMessage?.text == "Gira a la derecha en la Calle 19 y continúa 200 metros.")
}

@Test @MainActor func repeatAfterChangingDestinationSpeaksTheNewInstruction() async throws {
    let flow = IntegratedFlow(backend: .success(integrationBackendResponse))
    defer { flow.cleanUp() }
    _ = try await flow.service.createRoute(to: .query("Farmacia Central"))
    flow.geocoder.result = .success(park)
    flow.calculator.result = .success(parkCalculatedRoute())
    let updated = try await flow.modifier.changeDestination(to: .query("Parque de los Novios"))
    for _ in 0..<5 where flow.arbiter.currentMessage != nil { flow.player.finish() }
    #expect(flow.arbiter.currentMessage == nil)

    RouteInstructionRepeater(arbiter: flow.arbiter).repeatCurrentInstruction(of: updated)

    // El contexto de la revisión nueva no está invalidado: la repetición sí suena.
    #expect(flow.arbiter.currentMessage?.text == "Camina hacia el sur por la Calle 19 y continúa 80 metros.")
}
