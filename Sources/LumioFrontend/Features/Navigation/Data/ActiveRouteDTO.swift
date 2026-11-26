import Foundation

// Reflejan el contrato de /places/routes del backend (RouteCreate, RouteDestinationChange,
// RouteReroute y ActiveRoute). Cambiar destino envía el mismo cuerpo que crear la ruta;
// recalcular añade `rerouted_at`.

struct PlaceDTO: Codable, Equatable {
    let name: String
    let latitude: Double
    let longitude: Double

    init(_ place: RoutePlace) {
        name = place.name
        latitude = place.coordinate.latitude
        longitude = place.coordinate.longitude
    }
}

struct RouteStepDTO: Codable, Equatable {
    let order: Int
    let instruction: String
    let distanceMeters: Double
    let latitude: Double?
    let longitude: Double?

    enum CodingKeys: String, CodingKey {
        case order, instruction, latitude, longitude
        case distanceMeters = "distance_meters"
    }

    init(_ step: RouteStep) {
        order = step.order
        instruction = step.instruction
        distanceMeters = step.distanceMeters
        latitude = step.maneuverCoordinate?.latitude
        longitude = step.maneuverCoordinate?.longitude
    }
}

struct RouteCreateDTO: Encodable, Equatable {
    let origin: PlaceDTO
    let destination: PlaceDTO
    let steps: [RouteStepDTO]
    let distanceMeters: Double
    let expectedTravelTimeSeconds: Double

    enum CodingKeys: String, CodingKey {
        case origin, destination, steps
        case distanceMeters = "distance_meters"
        case expectedTravelTimeSeconds = "expected_travel_time_seconds"
    }

    init(_ route: ActiveRoute) {
        origin = PlaceDTO(route.origin)
        destination = PlaceDTO(route.destination)
        steps = route.steps.map(RouteStepDTO.init)
        distanceMeters = route.distanceMeters
        expectedTravelTimeSeconds = route.expectedTravelTimeSeconds
    }
}

/// Recalcular Ruta: el cuerpo de crear la ruta (mismo destino) más cuándo se recalculó.
struct RouteRerouteDTO: Encodable, Equatable {
    let route: RouteCreateDTO
    let reroutedAt: Date

    enum CodingKeys: String, CodingKey {
        case reroutedAt = "rerouted_at"
    }

    init(_ route: ActiveRoute, reroutedAt: Date) {
        self.route = RouteCreateDTO(route)
        self.reroutedAt = reroutedAt
    }

    func encode(to encoder: Encoder) throws {
        try route.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(BackendDate.string(from: reroutedAt), forKey: .reroutedAt)
    }
}

struct ActiveRouteResponseDTO: Decodable, Equatable {
    let id: UUID
    let status: String
    let currentStep: Int

    enum CodingKeys: String, CodingKey {
        case id, status
        case currentStep = "current_step"
    }
}
