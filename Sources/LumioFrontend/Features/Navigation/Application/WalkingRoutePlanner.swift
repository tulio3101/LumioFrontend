import Foundation

/// Recorrido peatonal ya normalizado, antes de convertirse en la ruta activa.
struct PlannedRoute: Equatable {
    let origin: RoutePlace
    let destination: RoutePlace
    let steps: [RouteStep]
    let distanceMeters: Double
    let expectedTravelTimeSeconds: Double
}

/// Mecanismo común de Crear Ruta y Modificar Ruta: valida el destino, toma la ubicación
/// actual (SCRUM-105/119), geocodifica si hace falta y calcula la ruta a pie (SCRUM-107).
/// Solo lanza RouteCreationError.
@MainActor
struct WalkingRoutePlanner {
    static let originName = "Ubicación actual"

    let location: any CurrentLocationProviding
    let geocoder: any DestinationGeocoding
    let calculator: any WalkingRouteCalculating
    var instructions = NavigationInstructionBuilder()

    func plan(to destination: DestinationRequest) async throws -> PlannedRoute {
        do {
            return try await calculate(destination)
        } catch let error as RouteCreationError {
            throw error
        } catch {
            throw RouteCreationError.serviceUnavailable
        }
    }

    private func calculate(_ destination: DestinationRequest) async throws -> PlannedRoute {
        let query: String?
        switch destination {
        case .query(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw RouteCreationError.emptyDestination }
            query = trimmed
        case .place(let place):
            guard place.coordinate.isValid else { throw RouteCreationError.destinationNotFound }
            query = nil
        }

        // Siempre una lectura nueva: la ruta parte de donde está el usuario ahora.
        let originCoordinate = try await location.currentLocation()
        guard originCoordinate.isValid else { throw RouteCreationError.locationUnavailable }
        let origin = RoutePlace(name: Self.originName, coordinate: originCoordinate)

        let target: RoutePlace
        switch destination {
        case .place(let place):
            target = place
        case .query:
            target = try await geocoder.place(for: query ?? "", near: originCoordinate)
            guard target.coordinate.isValid else { throw RouteCreationError.destinationNotFound }
        }

        let calculated = try await calculator.walkingRoute(from: origin, to: target)
        let steps = instructions.steps(from: calculated.steps)
        guard !steps.isEmpty, calculated.distanceMeters.isFinite, calculated.distanceMeters > 0 else {
            throw RouteCreationError.noRouteAvailable
        }
        let travelTime = calculated.expectedTravelTimeSeconds
        return PlannedRoute(
            origin: origin,
            destination: target,
            steps: steps,
            distanceMeters: calculated.distanceMeters,
            expectedTravelTimeSeconds: travelTime.isFinite ? max(0, travelTime) : 0
        )
    }
}
