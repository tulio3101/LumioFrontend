import Foundation
import Testing
@testable import LumioFrontend

/// Consultar Ruta Actual (SCRUM-23): avance estimado y textos de la respuesta.
///
/// Ruta recta hacia el norte por un meridiano, para que las distancias sean exactas:
///   origen ─200 m─ maniobra «Sigue recto» ─100 m─ destino (llegada sin punto).

private let metersPerDegree = 6_371_000 * Double.pi / 180

private func north(_ meters: Double, east: Double = 0) -> GeoCoordinate {
    let latitude = 4.6 + meters / metersPerDegree
    return GeoCoordinate(
        latitude: latitude,
        longitude: -74.08 + east / (metersPerDegree * cos(4.6 * .pi / 180))
    )
}

private let library = RoutePlace(name: "Biblioteca Nacional", coordinate: north(300))

private func lineRoute(
    currentStep: Int = 0, steps: [RouteStep]? = nil, travelTime: Double = 300
) -> ActiveRoute {
    ActiveRoute(
        id: UUID(),
        remoteID: nil,
        origin: RoutePlace(name: "Ubicación actual", coordinate: north(0)),
        destination: library,
        steps: steps ?? [
            RouteStep(order: 0, instruction: "Camina hacia el norte por la Carrera 7", distanceMeters: 200, maneuverCoordinate: north(0)),
            RouteStep(order: 1, instruction: "Sigue recto por la Calle 26", distanceMeters: 100, maneuverCoordinate: north(200)),
            RouteStep(order: 2, instruction: "El destino está a la izquierda", distanceMeters: 0, maneuverCoordinate: nil),
        ],
        distanceMeters: 300,
        expectedTravelTimeSeconds: travelTime,
        createdAt: Date(timeIntervalSince1970: 1_000),
        currentStep: currentStep
    )
}

private func isClose(_ value: Double?, _ expected: Double, tolerance: Double = 0.5) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < tolerance
}

private let estimator = RouteProgressEstimator()

// MARK: - Avance con ubicación (SCRUM-139)

@Test func atTheOriginNothingIsCoveredAndTheFirstStepIsNext() {
    let progress = estimator.progress(of: lineRoute(), at: north(0))

    #expect(progress.basis == .location)
    #expect(progress.nextStep?.order == 0)
    #expect(isClose(progress.distanceToNextMeters, 0))
    #expect(isClose(progress.distanceRemainingMeters, 300))
    #expect(progress.percent == 0)
    #expect(!progress.isArriving)
}

@Test func midwayTheNextManeuverAndRemainingDistanceComeFromThePosition() {
    let progress = estimator.progress(of: lineRoute(), at: north(120))

    #expect(progress.nextStep?.instruction == "Sigue recto por la Calle 26")
    #expect(isClose(progress.distanceToNextMeters, 80))
    #expect(isClose(progress.distanceCoveredMeters, 120))
    #expect(isClose(progress.distanceRemainingMeters, 180))
    #expect(progress.percent == 40)
    // El tiempo restante es proporcional a lo que falta.
    #expect(isClose(progress.remainingTimeSeconds, 180))
}

@Test func afterTheLastManeuverTheArrivalIsNext() {
    let progress = estimator.progress(of: lineRoute(), at: north(250))

    #expect(progress.nextStep?.instruction == "El destino está a la izquierda")
    #expect(isClose(progress.distanceToNextMeters, 50))
    #expect(isClose(progress.distanceRemainingMeters, 50))
    #expect(progress.percent == 83)
}

@Test func nearTheDestinationTheRouteIsArriving() {
    let progress = estimator.progress(of: lineRoute(), at: north(290))

    #expect(progress.isArriving)
    #expect(progress.nextStep?.instruction == "El destino está a la izquierda")
    #expect(isClose(progress.distanceRemainingMeters, 10))
}

@Test func walkingBesideTheRouteStillProjectsOntoIt() {
    let progress = estimator.progress(of: lineRoute(), at: north(120, east: 30))

    #expect(progress.nextStep?.order == 1)
    #expect(isClose(progress.distanceToNextMeters, 80))
}

@Test func walkingAwayFromTheOriginDoesNotCountAsProgress() {
    let progress = estimator.progress(of: lineRoute(), at: north(-100))

    #expect(progress.nextStep?.order == 0)
    #expect(progress.distanceCoveredMeters == 0)
    #expect(progress.percent == 0)
}

@Test func routeWithoutStepsOnlyHasTheDestinationAhead() {
    let progress = estimator.progress(of: lineRoute(steps: []), at: north(100))

    #expect(progress.nextStep == nil)
    #expect(isClose(progress.distanceToNextMeters, 200))
    #expect(progress.percent == 33)
}

// MARK: - Avance sin ubicación

@Test func withoutLocationTheStoredStepIsUsed() {
    let progress = estimator.progress(of: lineRoute(currentStep: 0), at: nil)

    #expect(progress.basis == .storedStep)
    #expect(progress.nextStep?.order == 0)
    #expect(progress.distanceToNextMeters == nil)
    #expect(progress.distanceRemainingMeters == 300)
}

@Test func storedStepCountsTheStepsAlreadyWalked() {
    let progress = estimator.progress(of: lineRoute(currentStep: 1), at: nil)

    #expect(progress.nextStep?.instruction == "Sigue recto por la Calle 26")
    #expect(progress.distanceCoveredMeters == 200)
    #expect(progress.distanceRemainingMeters == 100)
    #expect(progress.percent == 67)
}

@Test func invalidPositionFallsBackToTheStoredStep() {
    let progress = estimator.progress(of: lineRoute(), at: GeoCoordinate(latitude: 200, longitude: 0))

    #expect(progress.basis == .storedStep)
}

// MARK: - Respuesta por audio (SCRUM-137 / 138 / 140)

@Test func midwayAnswerSaysDestinationProgressAndNextInstruction() {
    let route = lineRoute()
    let status = RouteStatus.active(route, estimator.progress(of: route, at: north(120)))

    #expect(RouteStatusAnnouncements.text(for: status) ==
        "Vas hacia Biblioteca Nacional. Has recorrido el 40 por ciento: te faltan 180 metros, "
        + "unos 3 minutos caminando. Siguiente indicación en 80 metros: Sigue recto por la Calle 26.")
}

@Test func answerAtTheStartDoesNotSayZeroPercent() {
    let route = lineRoute()
    let status = RouteStatus.active(route, estimator.progress(of: route, at: north(0)))

    #expect(RouteStatusAnnouncements.text(for: status) ==
        "Vas hacia Biblioteca Nacional. Estás al inicio del recorrido: te faltan 300 metros, "
        + "unos 5 minutos caminando. Siguiente indicación: Camina hacia el norte por la Carrera 7.")
}

@Test func answerWithoutLocationSaysItIsApproximate() {
    let route = lineRoute()
    let status = RouteStatus.active(route, estimator.progress(of: route, at: nil))

    #expect(RouteStatusAnnouncements.text(for: status) ==
        "Vas hacia Biblioteca Nacional. No se pudo obtener tu ubicación, así que el avance es aproximado. "
        + "Estás al inicio del recorrido: te faltan 300 metros, unos 5 minutos caminando. "
        + "Siguiente indicación: Camina hacia el norte por la Carrera 7 y continúa 200 metros.")
}

@Test func answerWhenArrivingGivesTheArrivalInstruction() {
    let route = lineRoute()
    let status = RouteStatus.active(route, estimator.progress(of: route, at: north(290)))

    #expect(RouteStatusAnnouncements.text(for: status) ==
        "Vas hacia Biblioteca Nacional. Estás llegando: el destino está a menos de 25 metros. "
        + "El destino está a la izquierda.")
}

@Test func answerWithoutStepsSaysToReachTheDestination() {
    let route = lineRoute(steps: [])
    let status = RouteStatus.active(route, estimator.progress(of: route, at: north(100)))

    #expect(RouteStatusAnnouncements.text(for: status).hasSuffix("Lo siguiente es llegar a Biblioteca Nacional."))
}

@Test func answerWithoutTimeEstimateOmitsTheDuration() {
    let route = lineRoute(travelTime: 0)
    let status = RouteStatus.active(route, estimator.progress(of: route, at: north(120)))

    #expect(RouteStatusAnnouncements.text(for: status).contains("te faltan 180 metros. Siguiente"))
}

@Test func answersWithoutRoute() {
    #expect(RouteStatusAnnouncements.text(for: .noActiveRoute)
        == "No tienes una ruta activa. Indica un destino para crear una.")
    #expect(RouteStatusAnnouncements.text(for: .unreadable)
        == "No se pudo leer la ruta guardada en este teléfono. Indica el destino de nuevo para crear una ruta.")
}

// MARK: - Mensaje para el árbitro

@Test func statusMessageBelongsToTheRouteRevision() {
    var route = lineRoute()
    route.revision = 2
    let now = Date(timeIntervalSince1970: 5_000)
    let message = NavigationInstructionBuilder().statusMessage(
        .active(route, estimator.progress(of: route, at: north(120))), now: now
    )

    #expect(message.priority == .routeInformation)
    #expect(message.createdAt == now)
    #expect(message.contextID == "route-\(route.id.uuidString)-r2")
    #expect(message.deduplicationKey == "route-status")
}

@Test func statusMessageWithoutRouteUsesItsOwnContext() {
    let message = NavigationInstructionBuilder().statusMessage(.noActiveRoute, now: Date())

    #expect(message.contextID == NavigationInstructionBuilder.statusContextID)
    #expect(message.deduplicationKey == "route-status")
}
