/// Punto de composición: construir aquí implementaciones y compartirlas por sesión.
@MainActor
struct AppDependencies {
    let routeCreator: any RouteCreating
    let routeModifier: any RouteModifying
    let instructionRepeater: any InstructionRepeating
    let routeStatus: any RouteStatusQuerying
    let recentRoutes: any RecentRoutesQuerying
    let routeFinisher: any RouteFinishing
    let arrivalMonitor: any ArrivalMonitoring
    /// Se conserva mientras viva la app para reintentar el historial al volver la red.
    private let connectivity: (any ConnectivityObserving)?
    let destinationSuggester: any DestinationSuggesting
    let sessionService: any SessionRestoring
    let authenticationService: any Authenticating
    let signOut: any SigningOut
    #if canImport(AVFoundation)
    let audioArbiter: AudioArbiterService
    #endif
    #if os(iOS)
    /// nil si el modelo YOLO no está en el bundle (añadir yolo26n_640_int8.mlpackage a Copy Bundle Resources).
    let safetyService: SafetyService?
    #endif
    #if os(iOS)
    let permissions: PermissionsViewModel
    /// SCRUM-315: compuerta de permiso de cámara para arrancar la detección (SCRUM-33).
    let obstacleGate: (any CameraAssistanceGating)?
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

        // Crear, Modificar y Finalizar Ruta comparten copia local, backend, audio y háptica.
        let store = FileActiveRouteStore(fileURL: FileActiveRouteStore.defaultFileURL())
        let sync = RemoteActiveRouteService(client: routeClient, baseURL: configuration.apiBaseURL)
        // Rutas finalizadas pendientes de llegar al historial del backend.
        let history = FinishedRouteSynchronizer(
            store: FileFinishedRoutesStore(fileURL: FileFinishedRoutesStore.defaultFileURL()),
            finishSync: RemoteFinishedRouteService(client: routeClient, baseURL: configuration.apiBaseURL),
            routeSync: sync
        )
        let location = CoreLocationCurrentLocationProvider()
        let geocoder = MapKitDestinationGeocoder()
        let calculator = MapKitWalkingRouteCalculator()
        let haptics = UIKitHapticFeedback()
        routeCreator = RouteCreationService(
            location: location, geocoder: geocoder, calculator: calculator,
            store: store, sync: sync, arbiter: arbiter, haptics: haptics, history: history
        )
        routeModifier = RouteModificationService(
            location: location, geocoder: geocoder, calculator: calculator,
            store: store, sync: sync, arbiter: arbiter, haptics: haptics, history: history
        )
        let finisher = RouteFinishService(store: store, history: history, arbiter: arbiter, haptics: haptics)
        routeFinisher = finisher
        arrivalMonitor = ArrivalMonitor(tracker: CoreLocationRouteTracker(), store: store, finisher: finisher)
        instructionRepeater = RouteInstructionRepeater(arbiter: arbiter)
        // Consultar Ruta: solo copia local y GPS, sin backend.
        routeStatus = RouteStatusService(store: store, location: location, arbiter: arbiter)
        // Rutas recientes: backend con sesión y copia en el teléfono para usarla sin conexión.
        let recentStore = FileRecentRoutesStore(fileURL: FileRecentRoutesStore.defaultFileURL())
        recentRoutes = RecentRoutesService(
            history: RemoteRouteHistoryService(client: routeClient, baseURL: configuration.apiBaseURL),
            store: recentStore,
            arbiter: arbiter,
            pendingHistory: history
        )
        destinationSuggester = MapKitDestinationSuggester()
        signOut = SignOutService(
            session: session, routes: store, arbiter: arbiter,
            recentRoutes: recentStore, pendingHistory: history
        )
        // El historial pendiente se envía al abrir la app y cada vez que vuelve la conexión.
        let monitor = NetworkConnectivityMonitor()
        monitor.start { Task { await history.flush() } }
        connectivity = monitor
        Task { await history.flush() }
        #else
        #if canImport(AVFoundation)
        audioArbiter = AudioArbiterService(player: SpeechAudioPlayer())
        #endif
        let navigation = UnavailableNavigationService()
        routeCreator = navigation
        routeModifier = navigation
        instructionRepeater = navigation
        routeStatus = navigation
        recentRoutes = navigation
        routeFinisher = navigation
        arrivalMonitor = NoArrivalMonitoring()
        connectivity = nil
        destinationSuggester = NoDestinationSuggestions()
        sessionService = UnavailableSessionService()
        authenticationService = UnavailableAuthenticationService()
        signOut = SignOutService(
            session: UnavailableSessionService(), routes: NoActiveRouteStore(), arbiter: nil
        )
        #endif
        #if os(iOS)
        // SCRUM-37 (punto de extensión para Nestor): si el modelo YOLO no carga, aquí se
        // decide el manejo del error. Por ahora: guardar el fallo (modelAvailable) para que
        // la compuerta lo anuncie al iniciar la ruta, no al abrir la app, y seguir con la
        // navegación. Un reintento o un diagnóstico por tipo de error van en este catch.
        let modelAvailable: Bool
        do {
            let runner = try YOLORunner()
            let pipeline = DetectionPipeline(
                frameSource: ARKitFrameSource(),
                runner: runner,
                lowLightDetector: LowLightDetector(audioArbiter: audioArbiter)
            )
            self.safetyService = SafetyService(pipeline: pipeline, audioArbiter: audioArbiter)
            modelAvailable = true
        } catch {
            self.safetyService = nil
            modelAvailable = false
        }
        // Un solo PermissionService para la pantalla de permisos y para la compuerta de cámara.
        let permissionService = PermissionService(provider: IOSPermissionProvider())
        self.permissions = PermissionsViewModel(service: permissionService, audio: audioArbiter)
        self.obstacleGate = ObstacleAssistanceGate(
            permissions: permissionService, audio: audioArbiter, modelAvailable: modelAvailable
        )
        #endif
    }
}
