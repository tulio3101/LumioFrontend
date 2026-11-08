import Foundation

/// Crear Ruta: ubicación actual → destino geocodificado → ruta peatonal → instrucciones →
/// copia local → backend → anuncio por audio (prioridad 2) y háptica.
///
/// La ruta queda lista en cuanto existe la copia local: la guía no depende del backend.
/// Si el backend falla, la ruta se conserva como pendiente y se reintenta en
/// restoreActiveRoute().
@MainActor
final class RouteCreationService: RouteCreating {
    static let originName = "Ubicación actual"

    private let location: any CurrentLocationProviding
    private let geocoder: any DestinationGeocoding
    private let calculator: any WalkingRouteCalculating
    private let store: any ActiveRouteStoring
    private let sync: any ActiveRouteSyncing
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
        instructions: NavigationInstructionBuilder = NavigationInstructionBuilder(),
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> UUID = UUID.init
    ) {
        self.location = location
        self.geocoder = geocoder
        self.calculator = calculator
        self.store = store
        self.sync = sync
        self.arbiter = arbiter
        self.haptics = haptics ?? NoHapticFeedback()
        self.instructions = instructions
        self.now = now
        self.makeID = makeID
    }

    func createRoute(to destination: DestinationRequest) async throws -> ActiveRoute {
        let route: ActiveRoute
        do {
            route = try await calculateRoute(to: destination)
            let previous = try? store.load()
            do {
                try store.save(route)
            } catch {
                throw RouteCreationError.localStorageFailed
            }
            if let previous, previous.id != route.id {
                // Los mensajes pendientes de la ruta anterior dejan de ser relevantes.
                arbiter.updateContext(AudioDecisionContext(
                    invalidatedContextIDs: [NavigationInstructionBuilder.contextID(for: previous.id)]
                ))
            }
        } catch {
            let failure = (error as? RouteCreationError) ?? .serviceUnavailable
            arbiter.receive(instructions.failureMessage(failure, now: now()))
            haptics.play(.routeFailed)
            throw failure
        }
        announceReady(route)
        return await synchronize(route)
    }

    func restoreActiveRoute() async -> ActiveRoute? {
        guard let route = try? store.load() else { return nil }
        return route.isPendingBackendSync ? await synchronize(route) : route
    }

    private func calculateRoute(to destination: DestinationRequest) async throws -> ActiveRoute {
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
        return ActiveRoute(
            id: makeID(),
            remoteID: nil,
            origin: origin,
            destination: target,
            steps: steps,
            distanceMeters: calculated.distanceMeters,
            expectedTravelTimeSeconds: travelTime.isFinite ? max(0, travelTime) : 0,
            createdAt: now()
        )
    }

    private func announceReady(_ route: ActiveRoute) {
        arbiter.receive(instructions.readyMessage(for: route, now: now()))
        if let first = route.steps.first {
            arbiter.receive(instructions.message(for: first, routeID: route.id, now: now()))
        }
        haptics.play(.routeReady)
    }

    /// Persiste en el backend. Un fallo no invalida la ruta: queda pendiente.
    private func synchronize(_ route: ActiveRoute) async -> ActiveRoute {
        do {
            var synced = route
            synced.remoteID = try await sync.upload(route)
            try? store.save(synced)
            return synced
        } catch {
            return route
        }
    }
}
