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

/// Consultar Ruta Actual (SCRUM-23): estado de la ruta activa según su copia local, sin
/// backend. Siempre locuta la respuesta, también cuando no hay ruta activa.
@MainActor
protocol RouteStatusQuerying {
    func queryActiveRoute() async -> RouteStatus
}

/// Consultar Rutas Recientes (SCRUM-24): destinos de rutas anteriores, agrupados por lugar y
/// de la más reciente a la más antigua. Si el backend no responde, usa la última lista
/// guardada en el teléfono; sin ella, lanza RecentRoutesError.unavailable.
@MainActor
protocol RecentRoutesQuerying {
    /// Con `announce`, la respuesta (también «No tienes rutas recientes» o el fallo) se
    /// locuta por el AudioArbiter.
    func recentRoutes(announce: Bool) async throws -> RecentRoutes
}

/// Historial del backend (GET /places/routes/history): rutas completadas o canceladas, de
/// la más reciente a la más antigua.
@MainActor
protocol RouteHistoryFetching {
    func recentHistory(limit: Int) async throws -> [RouteHistoryEntry]
}

/// Copia en el teléfono de la última lista de destinos recientes, para usarla sin conexión.
@MainActor
protocol RecentRoutesStoring {
    func load() throws -> SavedRecentRoutes?
    func save(_ routes: SavedRecentRoutes) throws
    func clear() throws
}

/// Finalizar Ruta (SCRUM-10): detiene las instrucciones, borra la copia local, lo anuncia por
/// audio y háptica y deja la ruta en el historial (o pendiente si no hay red).
@MainActor
protocol RouteFinishing {
    /// nil si no hay ruta activa (también se anuncia).
    func finishActiveRoute(outcome: RouteHistoryEntry.Outcome, trigger: RouteFinishTrigger) async
        -> RouteFinishResult?
}

/// Rutas finalizadas que aún deben llegar al historial del backend. Se reintentan al abrir
/// la app, al volver la conexión, antes de subir otra ruta y antes de leer el historial.
@MainActor
protocol PendingHistorySyncing: AnyObject {
    func enqueue(_ finished: FinishedRoute) throws
    /// true si no queda nada pendiente.
    @discardableResult
    func flush() async -> Bool
    /// Al cerrar sesión: lo que no se pudo enviar no debe subirse con otra cuenta.
    func discardPending()
}

/// Backend de Finalizar Ruta.
@MainActor
protocol FinishedRouteSyncing {
    /// POST /places/routes/{remoteID}/finish. Lanza FinishedRouteSyncError.routeNotFound (404).
    func finish(remoteID: UUID, outcome: RouteHistoryEntry.Outcome, finishedAt: Date) async throws
    /// POST /places/routes/history: ruta que nunca llegó al backend. Lanza
    /// FinishedRouteSyncError.idConflict (409).
    func record(_ finished: FinishedRoute) async throws
}

enum FinishedRouteSyncError: Error, Equatable {
    case routeNotFound
    case idConflict
}

/// Cola en el teléfono de rutas finalizadas pendientes de enviar, en orden.
@MainActor
protocol FinishedRoutesStoring {
    func load() throws -> [FinishedRoute]
    func save(_ routes: [FinishedRoute]) throws
}

/// Lectura de GPS durante el trayecto.
struct LocationFix: Equatable {
    let coordinate: GeoCoordinate
    /// Radio de incertidumbre en metros; negativo si la lectura no es válida.
    let horizontalAccuracy: Double
}

/// Seguimiento continuo de la ubicación mientras hay ruta activa, también con el teléfono
/// bloqueado.
@MainActor
protocol LocationTracking: AnyObject {
    var onFix: ((LocationFix) -> Void)? { get set }
    func start()
    func stop()
}

/// Detecta la llegada al destino y finaliza la ruta (SCRUM-127).
@MainActor
protocol ArrivalMonitoring: AnyObject {
    var onArrival: (@MainActor (RouteFinishResult) -> Void)? { get set }
    /// Sin ruta activa no hace nada.
    func startMonitoring()
    func stopMonitoring()
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
    /// PUT /places/routes/{remoteID}/reroute (Recalcular Ruta). Lanza
    /// ActiveRouteSyncError.routeNoLongerOpen (404) o .rerouteRejected (409: ya no está
    /// abierta o el backend tiene otro destino).
    func reroute(_ route: ActiveRoute, remoteID: UUID, reroutedAt: Date) async throws
}

enum ActiveRouteSyncError: Error, Equatable {
    /// La ruta del backend terminó, se canceló o no existe (404/409).
    case routeNoLongerOpen
    /// El backend rechazó el recálculo (409). Se reenvía el recorrido completo como cambio de
    /// destino, que distingue si la ruta sigue abierta.
    case rerouteRejected
}

extension ActiveRouteSyncing {
    /// Lleva al backend el último cambio pendiente de una ruta que ya existe allí: el cambio
    /// de destino (que sustituye el recorrido completo) o, si no hay, el recálculo. Lanza
    /// ActiveRouteSyncError.routeNoLongerOpen si la ruta ya no está abierta en el backend.
    func pushPendingChanges(of route: ActiveRoute, remoteID: UUID) async throws {
        if route.hasPendingDestinationChange {
            try await updateDestination(of: route, remoteID: remoteID)
        } else if route.hasPendingReroute {
            do {
                try await reroute(route, remoteID: remoteID, reroutedAt: route.reroutedAt ?? route.createdAt)
            } catch ActiveRouteSyncError.rerouteRejected {
                try await updateDestination(of: route, remoteID: remoteID)
            }
        }
    }
}

/// Recalcular Ruta (SCRUM-26): nuevo recorrido hacia el mismo destino desde la ubicación
/// actual. Necesita red; anuncia por audio el resultado según el disparador.
@MainActor
protocol RouteRerouting {
    func reroute(trigger: RerouteTrigger) async -> RerouteOutcome
}

/// Vigila la posición durante la ruta y recalcula al desviarse (SCRUM-26).
@MainActor
protocol RouteDeviationMonitoring: AnyObject {
    /// nil cuando ya no hay nada que mostrar (volvió al trayecto o la ruta cambió).
    var onStatusChange: (@MainActor (RerouteStatus?) -> Void)? { get set }
    /// Sin ruta activa no hace nada.
    func startMonitoring()
    func stopMonitoring()
    /// «Recalcular ruta» a mano: sin esperas ni límite de intentos. nil si ya hay un
    /// recálculo en curso.
    @discardableResult
    func rerouteNow() async -> RerouteOutcome?
}

/// Eventos que vibran. Los de ruta se pueden apagar en Preferencias > Vibración; la alerta
/// crítica (P1 del AudioArbiter) vibra siempre. Patrones en HapticPattern.
enum HapticCue: String, Codable, CaseIterable, Equatable {
    case routeReady
    case routeFailed
    /// La navegación terminó (Finalizar Ruta).
    case routeFinished
    /// Una alerta de seguridad P1 empezó a sonar.
    case criticalAlert
}

/// Acompaña los anuncios de Crear Ruta. Los patrones de giro pertenecen a Guiar Giros.
/// En la app lo implementa HapticPreferencesService, que aplica las preferencias hápticas.
@MainActor
protocol HapticFeedbackPlaying {
    func play(_ cue: HapticCue)
}

struct NoHapticFeedback: HapticFeedbackPlaying {
    func play(_ cue: HapticCue) {}
}
