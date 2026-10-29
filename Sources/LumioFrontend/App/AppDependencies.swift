/// Punto de composición: construir aquí implementaciones y compartirlas por sesión.
/// Sustituir el servicio pendiente por MapKitNavigationService cuando exista.
@MainActor
struct AppDependencies {
    let navigationService: any NavigationPlanning
    let sessionService: any SessionRestoring
    let authenticationService: any Authenticating
    #if canImport(AVFoundation)
    let audioArbiter: AudioArbiterService
    #endif

    init(
        navigationService: any NavigationPlanning = UnavailableNavigationService(),
        sessionService: any SessionRestoring = UnavailableSessionService(),
        authenticationService: any Authenticating = UnavailableAuthenticationService()
    ) {
        self.navigationService = navigationService
        self.sessionService = sessionService
        self.authenticationService = authenticationService
        #if canImport(AVFoundation)
        self.audioArbiter = AudioArbiterService(player: SpeechAudioPlayer())
        #endif
    }
}
