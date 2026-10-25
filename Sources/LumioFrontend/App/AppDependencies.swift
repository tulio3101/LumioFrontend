/// Punto de composición: construir aquí implementaciones y compartirlas por sesión.
/// Sustituir el servicio pendiente por MapKitNavigationService cuando exista.
struct AppDependencies {
    let navigationService: any NavigationPlanning

    init(navigationService: any NavigationPlanning = UnavailableNavigationService()) {
        self.navigationService = navigationService
    }
}
