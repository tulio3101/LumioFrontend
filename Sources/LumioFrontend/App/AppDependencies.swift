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
    let profile: any ProfileManaging
    let contacts: any TrustedContactsManaging
    let accountDeleter: any AccountDeleting
    #if canImport(AVFoundation)
    let audioArbiter: AudioArbiterService
    #endif
    #if os(iOS)
    /// SCRUM-37: se crea siempre. Si falta el modelo o falla, lo informa `SafetyService.status`.
    /// Sigue siendo opcional para las vistas y pruebas que no usan detección.
    let safetyService: SafetyService?
    #endif
    #if os(iOS)
    let permissions: PermissionsViewModel
    /// SCRUM-315: compuerta de permiso de cámara para arrancar la detección (SCRUM-33).
    let obstacleGate: (any CameraAssistanceGating)?
    /// HU Interactuar mediante voz: escucha local, intérprete y respuestas por el árbitro.
    let voiceCommands: VoiceCommandService
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
        signOut = SignOutService(
            session: session, routes: store, arbiter: arbiter,
            recentRoutes: recentStore, pendingHistory: history
        )
        // Personalizar Cuenta: GET/PATCH /users/me y PUT /users/me/password con sesión.
        profile = ProfileService(
            remote: RemoteProfileService(client: routeClient, baseURL: configuration.apiBaseURL),
            tokens: tokens, arbiter: arbiter
        )
        // Contactos de Confianza: GET/POST/PUT/DELETE /contacts con sesión. Viven solo en el
        // backend: no hay copia local que borrar al cerrar sesión.
        contacts = TrustedContactsService(
            remote: RemoteTrustedContactsService(client: routeClient, baseURL: configuration.apiBaseURL),
            tokens: tokens, arbiter: arbiter
        )
        // Eliminar Cuenta: DELETE /users/me con sesión; después borra lo mismo que cerrar sesión.
        accountDeleter = AccountDeletionService(
            remote: RemoteAccountService(client: routeClient, baseURL: configuration.apiBaseURL),
            tokens: tokens, routes: store, recentRoutes: recentStore, pendingHistory: history,
            arbiter: arbiter
        )
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
        profile = ProfileService(
            remote: RemoteProfileService(client: URLSessionHTTPClient(), baseURL: nil), arbiter: nil
        )
        contacts = TrustedContactsService(
            remote: RemoteTrustedContactsService(client: URLSessionHTTPClient(), baseURL: nil), arbiter: nil
        )
        accountDeleter = AccountDeletionService(
            remote: RemoteAccountService(client: URLSessionHTTPClient(), baseURL: nil),
            tokens: NoTokenStore(), routes: NoActiveRouteStore(), arbiter: nil
        )
        #endif
        #if os(iOS)
        // SCRUM-37: SafetyService existe siempre, aunque el modelo falle. La carga de Core ML
        // ya no ocurre aquí (hilo principal): el pipeline la hace en RecoveringModel al iniciar
        // la detección (al iniciar la ruta), con reintentos 1/2/4 s para fallos recuperables.
        // Un modelo ausente o que no se recupera se publica en SafetyService.status y se avisa
        // por audio una sola vez; la navegación sigue y se ofrece «Reintentar detección».
        let focusConfig = DetectionFocusConfig()
        let pipeline = DetectionPipeline(
            frameSource: ARKitFrameSource(),
            runnerFactory: { try YOLORunner() },
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
        // La compuerta reutiliza el PermissionsViewModel de la pantalla de permisos para el flujo
        // accesible de solicitud de cámara.
        let permissionsViewModel = PermissionsViewModel(
            service: PermissionService(provider: IOSPermissionProvider()), audio: audioArbiter
        )
        self.permissions = permissionsViewModel
        self.obstacleGate = ObstacleAssistanceGate(
            permissions: permissionsViewModel, audio: audioArbiter
        )
        // Comandos de voz: reutilizan el flujo accesible de permisos y hablan por el árbitro.
        let voice = VoiceCommandService(
            listener: DeviceSpeechListener(),
            permissions: PermissionsVoiceGate(permissions: permissionsViewModel),
            audio: ArbiterVoiceAudio(arbiter: audioArbiter)
        )
        // Una alerta crítica que empieza a sonar corta la escucha (no compite con ella).
        audioArbiter.onMessageChanged = { [weak voice] message in
            voice?.audioMessageChanged(message)
        }
        self.voiceCommands = voice
        #endif
    }
}
