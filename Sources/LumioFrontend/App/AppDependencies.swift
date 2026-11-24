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
    let deviationMonitor: any RouteDeviationMonitoring
    /// Se conserva mientras viva la app para reintentar el historial y el recálculo al
    /// volver la red.
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
    /// SCRUM-360: al expirar la sesión (401 no renovable) desmonta la ruta activa y devuelve la UI
    /// al login, reutilizando el mismo teardown que el cierre de sesión.
    let sessionExpiry: SessionExpiryCoordinator
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
        // SCRUM-360: identidad de la cuenta para el historial pendiente por usuario.
        let account = UserDefaultsCurrentAccount()
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
            routeSync: sync,
            account: account
        )
        // SCRUM-360: al iniciar sesión, esta cuenta reenvía sus rutas finalizadas aparcadas.
        authenticationService = RemoteAuthenticationService(
            api: authAPI, store: tokens, account: account, pendingHistory: history
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
        // Llegada y desviación comparten una sola fuente de GPS durante la ruta.
        let tracking = SharedLocationTracker(base: CoreLocationRouteTracker())
        arrivalMonitor = ArrivalMonitor(tracker: tracking.makeClient(), store: store, finisher: finisher)
        // El estado de la red decide si se puede recalcular; al volver se reintenta.
        let monitor = NetworkConnectivityMonitor()
        let rerouter = RouteRerouteService(
            location: location, geocoder: geocoder, calculator: calculator,
            store: store, sync: sync, arbiter: arbiter, connectivity: monitor,
            haptics: haptics, history: history
        )
        deviationMonitor = RouteDeviationMonitor(
            tracker: tracking.makeClient(), store: store, rerouter: rerouter, connectivity: monitor
        )
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
        // SCRUM-360: `signOut` y `sessionExpiry` se arman más abajo, tras construir safetyService,
        // para que el teardown central incluya la detección de obstáculos.
        // El historial pendiente se envía al abrir la app y cada vez que vuelve la conexión.
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
        deviationMonitor = NoDeviationMonitoring()
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
            let focusConfig = DetectionFocusConfig()
            let pipeline = DetectionPipeline(
                frameSource: ARKitFrameSource(),
                runner: runner,
                lowLightDetector: LowLightDetector(audioArbiter: audioArbiter),
                focusConfig: focusConfig,
                pitchReminder: PhonePitchReminder(
                    audioArbiter: audioArbiter, cooldown: focusConfig.pitchReminderCooldown
                )
            )
            self.safetyService = SafetyService(
                pipeline: pipeline,
                audioArbiter: audioArbiter,
                announcer: ObstacleAnnouncer(
                    announcementInterval: focusConfig.perTrackCooldownSeconds,
                    dangerDistanceMeters: focusConfig.dangerDistanceMeters
                )
            )
            modelAvailable = true
        } catch {
            self.safetyService = nil
            modelAvailable = false
        }
        // La compuerta reutiliza el PermissionsViewModel de la pantalla de permisos para el flujo
        // accesible de solicitud de cámara.
        let permissionsViewModel = PermissionsViewModel(
            service: PermissionService(provider: IOSPermissionProvider()), audio: audioArbiter
        )
        self.permissions = permissionsViewModel
        self.obstacleGate = ObstacleAssistanceGate(
            permissions: permissionsViewModel, audio: audioArbiter, modelAvailable: modelAvailable
        )
        // SCRUM-360: punto único de desmonte, reutilizado por el cierre de sesión (SignOutService)
        // y por la expiración/401 (SessionExpiryCoordinator, vía .lumioSessionExpired).
        let teardown = SessionTeardown(
            safetyMonitor: self.safetyService,
            arrivalMonitor: arrivalMonitor,
            deviationMonitor: deviationMonitor,
            arbiter: arbiter,
            routes: store,
            recentRoutes: recentStore,
            pendingHistory: history
        )
        signOut = SignOutService(session: session, teardown: teardown)
        self.sessionExpiry = SessionExpiryCoordinator(teardown: teardown, routes: store, arbiter: arbiter)
        #endif
    }
}
