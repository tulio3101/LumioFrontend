/// Punto de composición: construir aquí implementaciones y compartirlas por sesión.
/// Sustituir el servicio pendiente por MapKitNavigationService cuando exista.
@MainActor
struct AppDependencies {
    let navigationService: any NavigationPlanning
    #if canImport(AVFoundation)
    let audioArbiter: AudioArbiterService
    #endif

    init(navigationService: any NavigationPlanning = UnavailableNavigationService()) {
        self.navigationService = navigationService
        #if canImport(AVFoundation)
        self.audioArbiter = AudioArbiterService(player: SpeechAudioPlayer())
        #endif
    }
}
