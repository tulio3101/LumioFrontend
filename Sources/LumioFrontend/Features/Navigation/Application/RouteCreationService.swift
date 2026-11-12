import Foundation

/// Crear Ruta: ubicación actual → destino geocodificado → ruta peatonal → instrucciones →
/// copia local → backend → anuncio por audio (prioridad 2) y háptica.
///
/// La ruta queda lista en cuanto existe la copia local: la guía no depende del backend.
/// Si el backend falla, la ruta se conserva como pendiente y se reintenta en
/// restoreActiveRoute().
@MainActor
final class RouteCreationService: RouteCreating {
    static let originName = WalkingRoutePlanner.originName

    private let planner: WalkingRoutePlanner
    private let store: any ActiveRouteStoring
    private let synchronizer: ActiveRouteSynchronizer
    private let arbiter: any AudioArbitrating
    private let haptics: any HapticFeedbackPlaying
    private let instructions: NavigationInstructionBuilder
    private let now: () -> Date
    private let makeID: () -> UUID

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
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> UUID = UUID.init
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
        self.makeID = makeID
    }

    func createRoute(to destination: DestinationRequest) async throws -> ActiveRoute {
        let route: ActiveRoute
        do {
            let planned = try await planner.plan(to: destination)
            route = ActiveRoute(
                id: makeID(),
                remoteID: nil,
                origin: planned.origin,
                destination: planned.destination,
                steps: planned.steps,
                distanceMeters: planned.distanceMeters,
                expectedTravelTimeSeconds: planned.expectedTravelTimeSeconds,
                createdAt: now()
            )
            let previous = try? store.load()
            do {
                try store.save(route)
            } catch {
                throw RouteCreationError.localStorageFailed
            }
            if let previous, previous.id != route.id {
                // Los mensajes pendientes de la ruta anterior dejan de ser relevantes.
                arbiter.updateContext(AudioDecisionContext(
                    invalidatedContextIDs: [NavigationInstructionBuilder.contextID(for: previous)]
                ))
            }
        } catch {
            let failure = (error as? RouteCreationError) ?? .serviceUnavailable
            arbiter.receive(instructions.failureMessage(failure, now: now()))
            haptics.play(.routeFailed)
            throw failure
        }
        arbiter.receive(instructions.readyMessage(for: route, now: now()))
        if let first = route.steps.first {
            arbiter.receive(instructions.message(for: first, in: route, now: now()))
        }
        haptics.play(.routeReady)
        return await synchronizer.synchronize(route)
    }

    /// Restaura la copia local y reintenta lo que quedó pendiente (creación o cambio de destino).
    func restoreActiveRoute() async -> ActiveRoute? {
        guard let route = try? store.load() else { return nil }
        return await synchronizer.synchronize(route)
    }
}
