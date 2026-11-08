import Foundation

struct GeoCoordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
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
    /// Identidad local; también agrupa sus mensajes de audio (contextID).
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

    var isPendingBackendSync: Bool { remoteID == nil }
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

/// Fallos de Crear Ruta. Cada uno tiene su anuncio en RouteAnnouncements.
enum RouteCreationError: Error, Equatable, CaseIterable {
    case emptyDestination
    case locationPermissionDenied
    case locationUnavailable
    case destinationNotFound
    case noRouteAvailable
    case localStorageFailed
    case serviceUnavailable
}
