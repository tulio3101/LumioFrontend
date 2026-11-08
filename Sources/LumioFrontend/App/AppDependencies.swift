/// Punto de composición: construir aquí implementaciones y compartirlas por sesión.
@MainActor
struct AppDependencies {
    let routeCreator: any RouteCreating
    let routeModifier: any RouteModifying
    let destinationSuggester: any DestinationSuggesting
    let sessionService: any SessionRestoring
    let authenticationService: any Authenticating
    let signOut: any SigningOut
    #if canImport(AVFoundation)
    let audioArbiter: AudioArbiterService
    #endif

    init(configuration: AppConfiguration = .main) {
        #if os(iOS)
        let arbiter = AudioArbiterService(player: SpeechAudioPlayer())
        audioArbiter = arbiter

        // Sesión: tokens en Keychain; las rutas se envían con el access token.
        let http = URLSessionHTTPClient()
        let tokens = KeychainTokenStore()
        let authAPI = configuration.apiBaseURL.map { AuthAPI(client: http, baseURL: $0) }
        let session = StoredSessionService(api: authAPI, store: tokens)
        sessionService = session
        authenticationService = RemoteAuthenticationService(api: authAPI, store: tokens)
        let routeClient: any HTTPClient = authAPI.map {
            AuthorizedHTTPClient(base: http, api: $0, store: tokens)
        } ?? http

        // Crear Ruta y Modificar Ruta comparten copia local, backend, audio y háptica.
        let store = FileActiveRouteStore(fileURL: FileActiveRouteStore.defaultFileURL())
        let sync = RemoteActiveRouteService(client: routeClient, baseURL: configuration.apiBaseURL)
        let location = CoreLocationCurrentLocationProvider()
        let geocoder = MapKitDestinationGeocoder()
        let calculator = MapKitWalkingRouteCalculator()
        let haptics = UIKitHapticFeedback()
        routeCreator = RouteCreationService(
            location: location, geocoder: geocoder, calculator: calculator,
            store: store, sync: sync, arbiter: arbiter, haptics: haptics
        )
        routeModifier = RouteModificationService(
            location: location, geocoder: geocoder, calculator: calculator,
            store: store, sync: sync, arbiter: arbiter, haptics: haptics
        )
        destinationSuggester = MapKitDestinationSuggester()
        signOut = SignOutService(session: session, routes: store, arbiter: arbiter)
        #else
        #if canImport(AVFoundation)
        audioArbiter = AudioArbiterService(player: SpeechAudioPlayer())
        #endif
        let navigation = UnavailableNavigationService()
        routeCreator = navigation
        routeModifier = navigation
        destinationSuggester = NoDestinationSuggestions()
        sessionService = UnavailableSessionService()
        authenticationService = UnavailableAuthenticationService()
        signOut = SignOutService(
            session: UnavailableSessionService(), routes: NoActiveRouteStore(), arbiter: nil
        )
        #endif
    }
}
