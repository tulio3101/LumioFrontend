import Foundation

/// Caso de uso Crear Ruta (SCRUM-8). Anuncia por audio el resultado, sea éxito o error.
@MainActor
protocol RouteCreating {
    func createRoute(to destination: DestinationRequest) async throws -> ActiveRoute
    /// Ruta activa de la copia local. Si quedó pendiente, se reintenta guardarla en el backend.
    func restoreActiveRoute() async -> ActiveRoute?
}

/// Caso de uso Modificar Ruta (SCRUM-9): cambia el destino de la ruta activa sin crear otra.
/// Recibe el destino por el mismo mecanismo que Crear Ruta (texto, sugerencia o, con
/// SCRUM-313, voz). Si no se puede calcular el nuevo recorrido, la ruta anterior sigue
/// activa y se lanza el RouteCreationError correspondiente, ya anunciado por audio.
@MainActor
protocol RouteModifying {
    func changeDestination(to destination: DestinationRequest) async throws -> ActiveRoute
}

/// Repetir la indicación actual cuando el usuario no la oyó (botón «Repetir indicación» o
/// Magic Tap de VoiceOver). Se locuta por el AudioArbiter, nunca desde la vista.
@MainActor
protocol InstructionRepeating {
    /// Vuelve a locutar la indicación actual. false si la ruta no tiene indicaciones.
    @discardableResult
    func repeatCurrentInstruction(of route: ActiveRoute) -> Bool
}

/// Posición actual con precisión suficiente para iniciar una ruta (SCRUM-105).
/// Lanza RouteCreationError.locationPermissionDenied o .locationUnavailable.
@MainActor
protocol CurrentLocationProviding {
    func currentLocation() async throws -> GeoCoordinate
}

/// Convierte el destino confirmado en una ubicación válida.
/// Lanza RouteCreationError.destinationNotFound o .serviceUnavailable.
@MainActor
protocol DestinationGeocoding {
    func place(for query: String, near origin: GeoCoordinate) async throws -> RoutePlace
}

/// Ruta peatonal entre dos puntos (SCRUM-107).
/// Lanza RouteCreationError.noRouteAvailable o .serviceUnavailable.
@MainActor
protocol WalkingRouteCalculating {
    func walkingRoute(from origin: RoutePlace, to destination: RoutePlace) async throws
        -> CalculatedRoute
}

/// Copia local de la ruta activa en el dispositivo.
@MainActor
protocol ActiveRouteStoring {
    func load() throws -> ActiveRoute?
    func save(_ route: ActiveRoute) throws
    func clear() throws
}

/// Persistencia de la ruta activa en el backend.
@MainActor
protocol ActiveRouteSyncing {
    /// PUT /places/routes/active. Devuelve el id que asigna el backend.
    func upload(_ route: ActiveRoute) async throws -> UUID
    /// PUT /places/routes/{remoteID}/destination. Lanza ActiveRouteSyncError.routeNoLongerOpen
    /// si el backend ya no tiene esa ruta abierta.
    func updateDestination(of route: ActiveRoute, remoteID: UUID) async throws
}

enum ActiveRouteSyncError: Error, Equatable {
    /// La ruta del backend terminó, se canceló o no existe (404/409).
    case routeNoLongerOpen
}

enum HapticCue: Equatable {
    case routeReady
    case routeFailed
}

/// Acompaña los anuncios de Crear Ruta. Los patrones de giro pertenecen a Guiar Giros.
@MainActor
protocol HapticFeedbackPlaying {
    func play(_ cue: HapticCue)
}

struct NoHapticFeedback: HapticFeedbackPlaying {
    func play(_ cue: HapticCue) {}
}
