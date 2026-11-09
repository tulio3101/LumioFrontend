/// Marcador para plataformas sin MapKit/CoreLocation (Linux, macOS en SwiftPM): no simula
/// una ruta válida ni activa el modo de asistencia.
struct UnavailableNavigationService: RouteCreating, RouteModifying, InstructionRepeating,
    RouteStatusQuerying, RecentRoutesQuerying, RouteFinishing {
    func createRoute(to destination: DestinationRequest) async throws -> ActiveRoute {
        throw FeatureUnavailable.navigation
    }

    func repeatCurrentInstruction(of route: ActiveRoute) -> Bool {
        false
    }

    func queryActiveRoute() async -> RouteStatus {
        .noActiveRoute
    }

    func recentRoutes(announce: Bool) async throws -> RecentRoutes {
        RecentRoutes(destinations: [], source: .backend)
    }

    func finishActiveRoute(
        outcome: RouteHistoryEntry.Outcome, trigger: RouteFinishTrigger
    ) async -> RouteFinishResult? {
        nil
    }

    func changeDestination(to destination: DestinationRequest) async throws -> ActiveRoute {
        throw FeatureUnavailable.navigation
    }

    func restoreActiveRoute() async -> ActiveRoute? {
        nil
    }
}

/// Copia local vacía para plataformas sin navegación.
struct NoActiveRouteStore: ActiveRouteStoring {
    func load() throws -> ActiveRoute? { nil }
    func save(_ route: ActiveRoute) throws {}
    func clear() throws {}
}
