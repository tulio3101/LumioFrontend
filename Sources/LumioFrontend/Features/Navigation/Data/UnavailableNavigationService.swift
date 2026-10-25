/// Marcador explícito: no simula una ruta válida ni activa el modo de asistencia.
struct UnavailableNavigationService: NavigationPlanning {
    func planRoute(to destination: String) async throws -> RoutePlan {
        throw FeatureUnavailable.navigation
    }
}
