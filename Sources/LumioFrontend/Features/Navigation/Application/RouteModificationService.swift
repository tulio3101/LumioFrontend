import Foundation

/// Modificar Ruta (SCRUM-9): nuevo recorrido hacia otro destino desde la ubicación actual,
/// sobre la misma ruta.
///
/// - Usa el mismo planificador que Crear Ruta (mismo mecanismo de destino y de cálculo).
/// - Si algo falla antes de guardar, la ruta anterior queda intacta y se anuncia por audio
///   que sigue activa.
/// - Si funciona, las instrucciones nuevas sustituyen a las anteriores: se invalidan los
///   mensajes pendientes del recorrido anterior, se anuncia «Ruta actualizada» con la
///   primera instrucción y se sincroniza con el backend (o queda pendiente).
@MainActor
final class RouteModificationService: RouteModifying {
    /// Destinos a menos de esta distancia del actual se consideran el mismo lugar.
    static let sameDestinationThresholdMeters = 25.0

    private let planner: WalkingRoutePlanner
    private let store: any ActiveRouteStoring
    private let synchronizer: ActiveRouteSynchronizer
    private let arbiter: any AudioArbitrating
    private let haptics: any HapticFeedbackPlaying
    private let instructions: NavigationInstructionBuilder
    private let now: () -> Date

    init(
        location: any CurrentLocationProviding,
        geocoder: any DestinationGeocoding,
        calculator: any WalkingRouteCalculating,
        store: any ActiveRouteStoring,
        sync: any ActiveRouteSyncing,
        arbiter: any AudioArbitrating,
        haptics: (any HapticFeedbackPlaying)? = nil,
        history: (any PendingHistorySyncing)? = nil,
        instructions: NavigationInstructionBuilder = NavigationInstructionBuilder(),
        now: @escaping () -> Date = Date.init
    ) {
        planner = WalkingRoutePlanner(
            location: location, geocoder: geocoder, calculator: calculator, instructions: instructions
        )
        self.store = store
        synchronizer = ActiveRouteSynchronizer(sync: sync, store: store, history: history)
        self.arbiter = arbiter
        self.haptics = haptics ?? NoHapticFeedback()
        self.instructions = instructions
        self.now = now
    }

    func changeDestination(to destination: DestinationRequest) async throws -> ActiveRoute {
        let current = try? store.load()
        let updated: ActiveRoute
        do {
            guard let current else { throw RouteCreationError.noActiveRoute }
            let planned = try await planner.plan(to: destination)
            let distance = planned.destination.coordinate.distance(to: current.destination.coordinate)
            guard distance > Self.sameDestinationThresholdMeters else {
                throw RouteCreationError.sameDestination
            }
            updated = ActiveRoute(
                id: current.id,
                remoteID: current.remoteID,
                origin: planned.origin,
                destination: planned.destination,
                steps: planned.steps,
                distanceMeters: planned.distanceMeters,
                expectedTravelTimeSeconds: planned.expectedTravelTimeSeconds,
                createdAt: current.createdAt,
                currentStep: 0,
                revision: current.revision + 1,
                // Si aún no existe en el backend, la sincronización la creará completa.
                hasPendingDestinationChange: current.remoteID != nil
            )
            do {
                try store.save(updated)
            } catch {
                throw RouteCreationError.localStorageFailed
            }
        } catch {
            let failure = (error as? RouteCreationError) ?? .serviceUnavailable
            FeedbackCatalog.emit(
                .routeModificationFailed(failure, keeping: current), audio: arbiter, haptics: haptics, now: now()
            )
            throw failure
        }

        if let current {
            arbiter.updateContext(AudioDecisionContext(
                invalidatedContextIDs: [NavigationInstructionBuilder.contextID(for: current)]
            ))
        }
        FeedbackCatalog.emit(.routeModified(updated), audio: arbiter, haptics: haptics, now: now())
        if let first = updated.steps.first {
            arbiter.receive(instructions.message(for: first, in: updated, now: now()))
        }
        return await synchronizer.synchronize(updated)
    }
}
