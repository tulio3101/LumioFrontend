/// Marcador para plataformas sin MapKit/CoreLocation (Linux, macOS en SwiftPM): no simula
/// una ruta válida ni activa el modo de asistencia.
struct UnavailableNavigationService: RouteCreating {
    func createRoute(to destination: DestinationRequest) async throws -> ActiveRoute {
        throw FeatureUnavailable.navigation
    }

    func restoreActiveRoute() async -> ActiveRoute? {
        nil
    }
}
