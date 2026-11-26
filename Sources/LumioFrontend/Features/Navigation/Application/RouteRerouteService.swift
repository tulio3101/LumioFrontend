import Foundation

/// Recalcular Ruta (SCRUM-26): nuevo recorrido hacia el mismo destino desde la ubicación
/// actual, sobre la misma ruta.
///
/// - Necesita red (MapKit calcula en línea). Sin conexión no se intenta: se anuncia que no
///   se puede recalcular y la guía sigue con la copia local.
/// - Antes de calcular se anuncia según el disparador («Te saliste de la ruta…»); un
///   reintento automático no repite avisos ni el fallo.
/// - Si funciona: misma ruta (mismo id), revisión +1, `currentStep` 0, copia local nueva; se
///   invalidan los mensajes del recorrido anterior, se anuncia «Ruta recalculada» con la
///   primera instrucción y se sincroniza con el backend (o queda pendiente).
/// - Si falla, la ruta anterior queda intacta y se anuncia que sigue activa.
@MainActor
final class RouteRerouteService: RouteRerouting {
    private let planner: WalkingRoutePlanner
    private let store: any ActiveRouteStoring
    private let synchronizer: ActiveRouteSynchronizer
    private let arbiter: any AudioArbitrating
    private let connectivity: any ConnectivityObserving
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
        connectivity: any ConnectivityObserving,
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
        self.connectivity = connectivity
        self.haptics = haptics ?? NoHapticFeedback()
        self.instructions = instructions
        self.now = now
    }

    func reroute(trigger: RerouteTrigger) async -> RerouteOutcome {
        guard let current = try? store.load() else {
            if trigger == .manual { speak(RerouteAnnouncements.noActiveRoute, key: "no-active-route") }
            return .noActiveRoute
        }
        guard connectivity.isConnected else {
            if trigger != .retry {
                FeedbackCatalog.emit(
                    .offline(destination: current.destination.name), audio: arbiter, haptics: haptics, now: now()
                )
            }
            return .offline
        }
        announceStart(trigger)

        let updated: ActiveRoute
        do {
            // El destino es un lugar ya ubicado: no se vuelve a geocodificar.
            let planned = try await planner.plan(to: .place(current.destination))
            // Mientras se calculaba el usuario pudo cambiar el destino o finalizar la ruta.
            guard let latest = try? store.load(), latest.id == current.id,
                  latest.revision == current.revision else { return .superseded }
            updated = ActiveRoute(
                id: current.id,
                remoteID: current.remoteID,
                origin: planned.origin,
                destination: current.destination,
                steps: planned.steps,
                distanceMeters: planned.distanceMeters,
                expectedTravelTimeSeconds: planned.expectedTravelTimeSeconds,
                createdAt: current.createdAt,
                currentStep: 0,
                revision: current.revision + 1,
                hasPendingDestinationChange: current.hasPendingDestinationChange,
                // Si aún no existe en el backend, la sincronización la creará completa.
                hasPendingReroute: current.remoteID != nil,
                reroutedAt: now()
            )
            do {
                try store.save(updated)
            } catch {
                throw RouteCreationError.localStorageFailed
            }
        } catch {
            let failure = (error as? RouteCreationError) ?? .serviceUnavailable
            if trigger != .retry {
                FeedbackCatalog.emit(
                    .rerouteFailed(failure, destination: current.destination.name),
                    audio: arbiter, haptics: haptics, now: now()
                )
            }
            return .failed(failure)
        }

        arbiter.updateContext(AudioDecisionContext(
            invalidatedContextIDs: [NavigationInstructionBuilder.contextID(for: current)]
        ))
        FeedbackCatalog.emit(.routeRecalculated(updated), audio: arbiter, haptics: haptics, now: now())
        if let first = updated.steps.first {
            arbiter.receive(instructions.message(for: first, in: updated, now: now()))
        }
        return .rerouted(await synchronizer.synchronize(updated))
    }

    private func announceStart(_ trigger: RerouteTrigger) {
        switch trigger {
        case .deviation: speak(RerouteAnnouncements.deviated, key: "deviated")
        case .manual: speak(RerouteAnnouncements.manual, key: "manual")
        case .reconnected: speak(RerouteAnnouncements.reconnected, key: "reconnected")
        case .retry: break
        }
    }

    private func speak(_ text: String, key: String) {
        arbiter.receive(instructions.rerouteNotice(text, key: key, now: now()))
    }
}
