/// Punto de composición: construir aquí implementaciones y compartirlas por sesión.
@MainActor
struct AppDependencies {
    let routeCreator: any RouteCreating
    let destinationSuggester: any DestinationSuggesting
    let sessionService: any SessionRestoring
    let authenticationService: any Authenticating
    #if canImport(AVFoundation)
    let audioArbiter: AudioArbiterService
    #endif

    init(
        routeCreator: (any RouteCreating)? = nil,
        destinationSuggester: (any DestinationSuggesting)? = nil,
        sessionService: any SessionRestoring = UnavailableSessionService(),
        authenticationService: any Authenticating = UnavailableAuthenticationService(),
        configuration: AppConfiguration = .main
    ) {
        self.sessionService = sessionService
        self.authenticationService = authenticationService
        #if os(iOS)
        self.destinationSuggester = destinationSuggester ?? MapKitDestinationSuggester()
        #else
        self.destinationSuggester = destinationSuggester ?? NoDestinationSuggestions()
        #endif
        #if canImport(AVFoundation)
        let arbiter = AudioArbiterService(player: SpeechAudioPlayer())
        self.audioArbiter = arbiter
        #endif
        if let routeCreator {
            self.routeCreator = routeCreator
        } else {
            #if os(iOS)
            self.routeCreator = RouteCreationService(
                location: CoreLocationCurrentLocationProvider(),
                geocoder: MapKitDestinationGeocoder(),
                calculator: MapKitWalkingRouteCalculator(),
                store: FileActiveRouteStore(fileURL: FileActiveRouteStore.defaultFileURL()),
                sync: RemoteActiveRouteService(
                    client: URLSessionHTTPClient(),
                    baseURL: configuration.apiBaseURL,
                    userID: configuration.devUserID
                ),
                arbiter: arbiter,
                haptics: UIKitHapticFeedback()
            )
            #else
            self.routeCreator = UnavailableNavigationService()
            #endif
        }
    }
}
