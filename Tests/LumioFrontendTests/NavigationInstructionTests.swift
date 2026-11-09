import Foundation
import Testing
@testable import LumioFrontend

@Test(arguments: zip(
    [0, 1, 7.4, 99.6, 123, 995, 1000, 1550, 2000, 12_340] as [Double],
    ["0 metros", "1 metro", "7 metros", "100 metros", "120 metros", "1 kilómetro",
     "1 kilómetro", "1,6 kilómetros", "2 kilómetros", "12,3 kilómetros"]
))
func distancesAreRoundedForSpeech(meters: Double, expected: String) {
    #expect(SpokenDistance.text(meters: meters) == expected)
}

@Test(arguments: zip(
    [20, 260, 3600, 3720, 7260] as [Double],
    ["1 minuto", "4 minutos", "1 hora", "1 hora y 2 minutos", "2 horas y 1 minuto"]
))
func durationsAreRoundedForSpeech(seconds: Double, expected: String) {
    #expect(SpokenDuration.text(seconds: seconds) == expected)
}

@Test func approximateDurationAgreesInNumber() {
    #expect(SpokenDuration.approximate(seconds: 70) == "alrededor de 1 minuto")
    #expect(SpokenDuration.approximate(seconds: 260) == "unos 4 minutos")
    #expect(SpokenDuration.approximate(seconds: 0) == nil)
}

@Test func missingDurationIsNotAnnounced() {
    #expect(SpokenDuration.text(seconds: 0) == nil)
    #expect(SpokenDuration.text(seconds: .nan) == nil)
}

@Test func stepsDropEmptyInstructionsAndAreNumberedFromZero() {
    let steps = NavigationInstructionBuilder().steps(from: sampleCalculatedRoute().steps)

    #expect(steps.map(\.order) == [0, 1])
    #expect(steps.map(\.instruction) == [
        "Gira a la derecha en la Calle 19", "El destino está a la izquierda",
    ])
    #expect(steps[0].maneuverCoordinate == GeoCoordinate(latitude: 4.6108, longitude: -74.0815))
}

@Test func instructionsAreNormalizedForSpeech() {
    let steps = NavigationInstructionBuilder().steps(from: [
        CalculatedRouteStep(instruction: "  Gira a la\nizquierda   en la Calle 5.  ",
                            distanceMeters: -3,
                            maneuverCoordinate: GeoCoordinate(latitude: 200, longitude: 0)),
        CalculatedRouteStep(instruction: " \n ", distanceMeters: 10, maneuverCoordinate: nil),
    ])

    #expect(steps == [RouteStep(order: 0, instruction: "Gira a la izquierda en la Calle 5",
                                distanceMeters: 0, maneuverCoordinate: nil)])
}

@Test func spokenStepIncludesDistanceToWalk() {
    let builder = NavigationInstructionBuilder()
    let turn = RouteStep(order: 0, instruction: "Gira a la derecha en la Calle 19",
                         distanceMeters: 200, maneuverCoordinate: nil)
    let arrival = RouteStep(order: 1, instruction: "El destino está a la izquierda",
                            distanceMeters: 0, maneuverCoordinate: nil)

    #expect(builder.spokenText(for: turn) == "Gira a la derecha en la Calle 19 y continúa 200 metros.")
    #expect(builder.spokenText(for: arrival) == "El destino está a la izquierda.")
}

@Test func stepMessagesAreNavigationPriorityGroupedByRoute() {
    let step = RouteStep(order: 3, instruction: "Gira", distanceMeters: 5, maneuverCoordinate: nil)
    let route = sampleActiveRoute()
    let message = NavigationInstructionBuilder().message(for: step, in: route, now: Date())

    #expect(message.priority == .routeInformation)
    #expect(message.contextID == "route-\(route.id.uuidString)")
    #expect(message.deduplicationKey == "step-3")
}

@Test func eachDestinationChangeHasItsOwnAudioContext() {
    var route = sampleActiveRoute()
    let original = NavigationInstructionBuilder.contextID(for: route)
    route.revision = 2

    #expect(NavigationInstructionBuilder.contextID(for: route) == "route-\(route.id.uuidString)-r2")
    #expect(NavigationInstructionBuilder.contextID(for: route) != original)
}

@Test func updatedRouteIsAnnouncedWithItsSummary() {
    var route = sampleActiveRoute()
    route.revision = 1

    let message = NavigationInstructionBuilder().updatedMessage(for: route, now: Date())

    #expect(message.text == "Ruta actualizada hacia Farmacia Central. Son 320 metros, unos 4 minutos caminando.")
    #expect(message.priority == .routeInformation)
    #expect(message.contextID == NavigationInstructionBuilder.contextID(for: route))
    #expect(message.deduplicationKey == "route-updated")
}

@Test(arguments: RouteCreationError.allCases.filter { $0 != .noActiveRoute })
func failedChangeSaysThePreviousRouteContinues(error: RouteCreationError) {
    let message = NavigationInstructionBuilder()
        .modificationFailureMessage(error, keeping: sampleActiveRoute(), now: Date())

    #expect(message.text.hasPrefix("No se pudo cambiar el destino. \(RouteAnnouncements.failure(error))"))
    #expect(message.text.hasSuffix("Sigues con la ruta hacia Farmacia Central."))
    #expect(message.priority == .routeInformation)
    #expect(message.contextID == NavigationInstructionBuilder.modificationFailureContextID)
}

@Test func changeWithoutActiveRouteOnlyExplainsWhy() {
    #expect(RouteAnnouncements.modificationFailure(.noActiveRoute, keeping: nil)
        == "No hay una ruta activa para cambiar. Indica un destino para crear una.")
}

private func sampleActiveRoute() -> ActiveRoute {
    ActiveRoute(
        id: UUID(),
        remoteID: nil,
        origin: RoutePlace(name: "Ubicación actual", coordinate: currentPosition),
        destination: pharmacy,
        steps: NavigationInstructionBuilder().steps(from: sampleCalculatedRoute().steps),
        distanceMeters: 320,
        expectedTravelTimeSeconds: 260,
        createdAt: Date()
    )
}

@Test(arguments: RouteCreationError.allCases)
func everyFailureHasASpokenNavigationMessage(error: RouteCreationError) {
    let message = NavigationInstructionBuilder().failureMessage(error, now: Date())

    #expect(!message.text.isEmpty)
    #expect(message.text == RouteAnnouncements.failure(error))
    #expect(message.priority == .routeInformation)
    #expect(message.contextID == NavigationInstructionBuilder.failureContextID)
}

@Test func readyAnnouncementOmitsMissingDuration() {
    let route = ActiveRoute(
        id: UUID(), origin: pharmacy, destination: pharmacy, steps: [],
        distanceMeters: 1500, expectedTravelTimeSeconds: 0, createdAt: Date()
    )

    #expect(RouteAnnouncements.ready(route) == "Ruta lista hacia Farmacia Central. Son 1,5 kilómetros.")
}
