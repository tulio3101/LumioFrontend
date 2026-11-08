import Foundation

struct GeoCoordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    /// Distancia aproximada en metros (haversine); suficiente para comparar destinos.
    func distance(to other: GeoCoordinate) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }
}

struct RoutePlace: Codable, Equatable {
    let name: String
    let coordinate: GeoCoordinate
}

/// Paso de la ruta con su instrucción ya normalizada para locutar.
struct RouteStep: Codable, Equatable {
    let order: Int
    let instruction: String
    /// Distancia que se recorre después de la maniobra.
    let distanceMeters: Double
    /// Punto donde empieza la maniobra; Guiar Giros (SCRUM-312) lo usa para anunciarla a tiempo.
    let maneuverCoordinate: GeoCoordinate?
}

/// Ruta activa. Esta es la copia local que usan la guía y la consulta de la ruta sin backend.
struct ActiveRoute: Codable, Equatable, Identifiable {
    /// Identidad local. Se conserva al cambiar el destino (Modificar Ruta).
    let id: UUID
    /// Identificador asignado por el backend. Es nil mientras la ruta no se haya persistido allí.
    var remoteID: UUID?
    let origin: RoutePlace
    let destination: RoutePlace
    let steps: [RouteStep]
    let distanceMeters: Double
    let expectedTravelTimeSeconds: Double
    let createdAt: Date
    var currentStep: Int = 0
    /// Versión del recorrido: sube con cada cambio de destino. Separa el audio de las
    /// instrucciones anteriores del de las nuevas (ver NavigationInstructionBuilder.contextID).
    var revision: Int = 0
    /// El backend todavía no conoce el último cambio de destino.
    var hasPendingDestinationChange = false

    var isPendingBackendSync: Bool { remoteID == nil || hasPendingDestinationChange }

    enum CodingKeys: String, CodingKey {
        case id, remoteID, origin, destination, steps, distanceMeters, expectedTravelTimeSeconds
        case createdAt, currentStep, revision, hasPendingDestinationChange
    }
}

extension ActiveRoute {
    /// Las copias locales guardadas antes de Modificar Ruta no tienen `revision` ni
    /// `hasPendingDestinationChange`: se leen con sus valores por defecto.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        remoteID = try container.decodeIfPresent(UUID.self, forKey: .remoteID)
        origin = try container.decode(RoutePlace.self, forKey: .origin)
        destination = try container.decode(RoutePlace.self, forKey: .destination)
        steps = try container.decode([RouteStep].self, forKey: .steps)
        distanceMeters = try container.decode(Double.self, forKey: .distanceMeters)
        expectedTravelTimeSeconds = try container.decode(Double.self, forKey: .expectedTravelTimeSeconds)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        currentStep = try container.decodeIfPresent(Int.self, forKey: .currentStep) ?? 0
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        hasPendingDestinationChange = try container.decodeIfPresent(
            Bool.self, forKey: .hasPendingDestinationChange
        ) ?? false
    }
}

/// Destino ya confirmado por el usuario. Punto de extensión de Indicar Destino por Voz
/// (SCRUM-313): el dictado entrega el texto confirmado o un lugar ya geocodificado.
enum DestinationRequest: Equatable {
    case query(String)
    case place(RoutePlace)
}

/// Ruta peatonal tal como la devuelve el proveedor (MapKit), antes de normalizarla.
struct CalculatedRoute: Equatable {
    let distanceMeters: Double
    let expectedTravelTimeSeconds: Double
    let steps: [CalculatedRouteStep]
}

struct CalculatedRouteStep: Equatable {
    let instruction: String
    let distanceMeters: Double
    let maneuverCoordinate: GeoCoordinate?
}

/// Fallos de Crear Ruta y Modificar Ruta. Cada uno tiene su anuncio en RouteAnnouncements.
enum RouteCreationError: Error, Equatable, CaseIterable {
    case emptyDestination
    case locationPermissionDenied
    case locationUnavailable
    case destinationNotFound
    case noRouteAvailable
    case localStorageFailed
    case serviceUnavailable
    /// Modificar Ruta: no hay ruta activa cuyo destino cambiar.
    case noActiveRoute
    /// Modificar Ruta: el destino nuevo es el mismo que el actual.
    case sameDestination
}
