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
    /// Botón de Emergencia (SCRUM-35): margen para cancelar y alerta por correo a los contactos.
    let emergency: any EmergencyManaging
    let accountDeleter: any AccountDeleting
    /// Configurar Preferencias de Voz Descriptiva: se leen del teléfono y se aplican al
    /// reproductor del árbitro al abrir la app, antes de la primera locución.
    let voicePreferences: VoicePreferencesService
    /// Configurar Retroalimentación Háptica: todos los eventos que vibran pasan por aquí; se
    /// leen del teléfono al abrir la app. Las alertas críticas vibran siempre.
    let hapticPreferences: HapticPreferencesService
    #if canImport(AVFoundation)
    let audioArbiter: AudioArbiterService
    #endif
    #if os(iOS)
    /// SCRUM-37: se crea siempre. Si falta el modelo o falla, lo informa `SafetyService.status`.
    /// Sigue siendo opcional para las vistas y pruebas que no usan detección.
    let safetyService: SafetyService?
    /// SCRUM-360: al expirar la sesión (401 no renovable) desmonta la ruta activa y devuelve la UI
    /// al login, reutilizando el mismo teardown que el cierre de sesión.
    let sessionExpiry: SessionExpiryCoordinator
    #endif
    #if os(iOS)
    let permissions: PermissionsViewModel
    /// SCRUM-315: compuerta de permiso de cámara para arrancar la detección (SCRUM-33).
    let obstacleGate: (any CameraAssistanceGating)?
    /// HU Interactuar mediante voz: escucha local, intérprete y respuestas por el árbitro.
    let voiceCommands: VoiceCommandService
    /// Pantalla Principal Accesible: sesión, permisos, seguridad y ruta, locutados al abrir.
    let homeStatus: HomeStatusService
    /// Copia de respaldo de las preferencias de voz y vibración en el backend.
    let preferencesSync: PreferencesSynchronizer
    /// SCRUM-324: consentimiento para enviar fotos a la narración; solo en el teléfono.
    let narrationConsent: NarrationConsentService
    /// SCRUM-32: narración automática y avisos; solo en el teléfono, se leen en memoria.
    let accessibilityPreferences: AccessibilityPreferencesService
    /// Recuperar Contraseña: POST /users/password-reset y /confirm, sin sesión.
    let passwordRecovery: PasswordRecoveryService
    /// SCRUM-38: «Describir entorno» en la ruta. Usa la cámara de la seguridad sin frenarla.
    let environmentNarration: EnvironmentNarrationService
    #endif

    init(configuration: AppConfiguration = .main) {
        #if os(iOS)
        let player = SpeechAudioPlayer()
        let arbiter = AudioArbiterService(player: player)
        audioArbiter = arbiter
        // Preferencias de voz: solo copia local; nunca esperan a la red.
        let voiceSettings = VoicePreferencesService(
            store: FileVoicePreferencesStore(fileURL: FileVoicePreferencesStore.defaultFileURL()),
            catalog: SystemVoiceCatalog(),
            output: player,
            arbiter: arbiter
        )
        voicePreferences = voiceSettings
        // Preferencias hápticas: solo copia local; filtran los eventos antes de vibrar.
        let hapticSettings = HapticPreferencesService(
            store: FileHapticPreferencesStore(fileURL: FileHapticPreferencesStore.defaultFileURL()),
            player: UIKitHapticFeedback(),
            arbiter: arbiter
        )
        hapticPreferences = hapticSettings
        // SCRUM-32: preferencias de accesibilidad, solo en el teléfono y en memoria.
        let accessibility = AccessibilityPreferencesService(
            store: FileAccessibilityPreferencesStore(fileURL: FileAccessibilityPreferencesStore.defaultFileURL()),
            arbiter: arbiter
        )
        accessibilityPreferences = accessibility

        // Sesión: tokens en Keychain; las rutas se envían con el access token.
        let http = URLSessionHTTPClient()
        let tokens = KeychainTokenStore()
        let authAPI = configuration.apiBaseURL.map { AuthAPI(client: http, baseURL: $0) }
        let session = StoredSessionService(api: authAPI, store: tokens)
        sessionService = session
        // SCRUM-360: identidad de la cuenta para el historial pendiente por usuario.
        let account = UserDefaultsCurrentAccount()
        passwordRecovery = PasswordRecoveryService(
            remote: RemotePasswordRecoveryService(client: http, baseURL: configuration.apiBaseURL),
            arbiter: arbiter
        )
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
        // SCRUM-62: pantalla de Google (OAuth con PKCE); nil sin GoogleClientID en el Info.plist.
        let google = configuration.google.map { WebGoogleIDTokenProvider(configuration: $0, client: http) }
        let location = CoreLocationCurrentLocationProvider()
        let geocoder = MapKitDestinationGeocoder()
        let calculator = MapKitWalkingRouteCalculator()
        let haptics = hapticSettings
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
        // SCRUM-360: al iniciar sesión, esta cuenta reenvía sus rutas finalizadas aparcadas.
        // SCRUM-62: Google avisa por el árbitro la cancelación, la falta de red y los errores.
        authenticationService = AnnouncedAuthenticationService(
            base: RemoteAuthenticationService(
                api: authAPI, store: tokens, google: google, account: account, pendingHistory: history
            ),
            announcer: GoogleSignInAnnouncer(arbiter: arbiter, connectivity: monitor)
        )
        let rerouter = RouteRerouteService(
            location: location, geocoder: geocoder, calculator: calculator,
            store: store, sync: sync, arbiter: arbiter, connectivity: monitor,
            haptics: haptics, history: history
        )
        deviationMonitor = RouteDeviationMonitor(
            tracker: tracking.makeClient(), store: store, rerouter: rerouter, connectivity: monitor
        )
        // Guiar Giros (SCRUM-312): escucha la misma fuente de GPS mientras la siguen la llegada y
        // la desviación (es decir, mientras hay ruta activa). Solo copia local, sin backend.
        tracking.addObserver(TurnGuidanceMonitor(
            store: store, arbiter: arbiter, haptics: haptics, connectivity: monitor
        ))
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
        // Personalizar Cuenta: GET/PATCH /users/me y PUT /users/me/password con sesión.
        // SCRUM-62: también asocia una cuenta de Google (POST /users/me/google).
        profile = ProfileService(
            remote: RemoteProfileService(client: routeClient, baseURL: configuration.apiBaseURL),
            tokens: tokens, arbiter: arbiter, google: google, connectivity: monitor
        )
        // Contactos de Confianza: GET/POST/PUT/DELETE /contacts con sesión. Viven solo en el
        // backend: no hay copia local que borrar al cerrar sesión.
        let contactsRemote = RemoteTrustedContactsService(client: routeClient, baseURL: configuration.apiBaseURL)
        contacts = TrustedContactsService(remote: contactsRemote, tokens: tokens, arbiter: arbiter)
        // Botón de Emergencia: POST /sos con sesión. La ubicación no pide permiso (nil si falta) y
        // los contactos se cuentan sin audio para avisar de inmediato si no hay ninguno.
        emergency = EmergencyService(
            remote: RemoteEmergencyService(client: routeClient, baseURL: configuration.apiBaseURL),
            locator: CoreLocationEmergencyLocator(),
            connectivity: monitor,
            contactCount: { try? await contactsRemote.listContacts().count },
            tokens: tokens, arbiter: arbiter, haptics: haptics
        )
        // Eliminar Cuenta: DELETE /users/me con sesión; después borra lo mismo que cerrar sesión.
        accountDeleter = AccountDeletionService(
            remote: RemoteAccountService(client: routeClient, baseURL: configuration.apiBaseURL),
            tokens: tokens, routes: store, recentRoutes: recentStore, pendingHistory: history,
            voicePreferences: voiceSettings, hapticPreferences: hapticSettings,
            accessibilityPreferences: accessibility, arbiter: arbiter
        )
        // Preferencias de voz y vibración: se aplican del teléfono y se respaldan en
        // GET/PUT /users/me/preferences en segundo plano; nunca retrasan el audio.
        let preferencesSynchronizer = PreferencesSynchronizer(
            remote: RemotePreferencesService(client: routeClient, baseURL: configuration.apiBaseURL),
            stateStore: FilePreferencesSyncStateStore(fileURL: FilePreferencesSyncStateStore.defaultFileURL()),
            voice: voiceSettings,
            haptics: hapticSettings
        )
        voiceSettings.onPreferencesChanged = { [weak preferencesSynchronizer] in
            preferencesSynchronizer?.localPreferencesChanged()
        }
        hapticSettings.onPreferencesChanged = { [weak preferencesSynchronizer] in
            preferencesSynchronizer?.localPreferencesChanged()
        }
        preferencesSync = preferencesSynchronizer
        monitor.start { Task { await preferencesSynchronizer.synchronize() } }
        // El historial pendiente se envía al abrir la app y cada vez que vuelve la conexión.
        monitor.start { Task { await history.flush() } }
        connectivity = monitor
        Task { await history.flush() }
        #else
        #if canImport(AVFoundation)
        let player = SpeechAudioPlayer()
        let arbiter = AudioArbiterService(player: player)
        audioArbiter = arbiter
        voicePreferences = VoicePreferencesService(
            store: FileVoicePreferencesStore(fileURL: FileVoicePreferencesStore.defaultFileURL()),
            catalog: SystemVoiceCatalog(),
            output: player,
            arbiter: arbiter
        )
        #else
        voicePreferences = VoicePreferencesService(
            store: FileVoicePreferencesStore(fileURL: FileVoicePreferencesStore.defaultFileURL()),
            catalog: NoVoiceCatalog(),
            output: nil,
            arbiter: nil
        )
        #endif
        hapticPreferences = HapticPreferencesService(
            store: FileHapticPreferencesStore(fileURL: FileHapticPreferencesStore.defaultFileURL()),
            player: nil,
            arbiter: nil
        )
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
        emergency = EmergencyService(
            remote: RemoteEmergencyService(client: URLSessionHTTPClient(), baseURL: nil),
            locator: NoEmergencyLocation(), connectivity: AssumeConnected(),
            arbiter: nil, haptics: NoHapticFeedback()
        )
        accountDeleter = AccountDeletionService(
            remote: RemoteAccountService(client: URLSessionHTTPClient(), baseURL: nil),
            tokens: NoTokenStore(), routes: NoActiveRouteStore(), arbiter: nil
        )
        #endif
        #if os(iOS)
        // SCRUM-37: SafetyService existe siempre, aunque el modelo falle. La carga de Core ML
        // nunca ocurre en el hilo principal. Un modelo ausente o que no se recupera se publica
        // en SafetyService.status y se avisa por audio una sola vez; la navegación sigue y se
        // ofrece «Reintentar detección».
        // SCRUM-314: el modelo se carga una sola vez (ReusableModelLoader) y se precarga en
        // segundo plano al abrir la app; cada ruta reutiliza el mismo. La precarga no espera
        // a la red ni retrasa la pantalla principal.
        let detectorLoader = ReusableModelLoader<any ObstacleDetecting> { try YOLORunner() }
        detectorLoader.warmUp()
        let focusConfig = DetectionFocusConfig()
        // La narración (SCRUM-38) toma sus fotos de la misma sesión de ARKit.
        let frameSource = ARKitFrameSource()
        let pipeline = DetectionPipeline(
            frameSource: frameSource,
            runnerFactory: { try detectorLoader.load() },
            discardRunner: { detectorLoader.discard() },
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
                proximity: focusConfig.proximity
            ),
            haptics: haptics
        )
        // La compuerta reutiliza el PermissionsViewModel de la pantalla de permisos para el flujo
        // accesible de solicitud de cámara.
        let permissionService = PermissionService(provider: IOSPermissionProvider())
        let permissionsViewModel = PermissionsViewModel(service: permissionService, audio: audioArbiter)
        self.permissions = permissionsViewModel
        self.obstacleGate = ObstacleAssistanceGate(
            permissions: permissionsViewModel, audio: audioArbiter
        )
        // Comandos de voz: reutilizan el flujo accesible de permisos y hablan por el árbitro.
        let consent = NarrationConsentService(
            store: FileNarrationConsentStore(fileURL: FileNarrationConsentStore.defaultFileURL()),
            arbiter: audioArbiter
        )
        narrationConsent = consent
        // Narración del Entorno: POST /vision/analyze con sesión; la descripción suena como P3.
        let narration = EnvironmentNarrationService(
            capturer: frameSource,
            describer: RemoteEnvironmentNarrationService(
                client: routeClient, baseURL: configuration.apiBaseURL
            ),
            consent: consent,
            connectivity: monitor,
            arbiter: audioArbiter,
            tokens: tokens,
            // SCRUM-39: una escena igual a la recién descrita se repite sin enviar otra foto.
            signatures: VisionSceneSignatureProvider()
        )
        // SCRUM-40: con la ruta activa, la escena que cambia pide sola otra descripción (huella
        // VNFeaturePrint en el teléfono, mínimo 10 s entre narraciones y solo con el canal libre).
        narration.autoUpdates = AutoNarrationScheduler(
            service: narration,
            capturer: frameSource,
            signatures: VisionSceneSignatureProvider(),
            consent: consent,
            connectivity: monitor,
            channel: audioArbiter,
            // SCRUM-32: el usuario puede apagar la narración automática.
            isEnabled: { [weak accessibility] in accessibility?.preferences.autoNarration ?? true }
        )
        // SCRUM-41: durante la ruta vigila la red y GET /vision/status (sin sesión ni foto).
        // Avisa por el árbitro (P2) y con vibración al caer y al volver; mientras está caída no
        // salen fotos automáticas y al volver se reanudan. La detección no depende de esto.
        narration.availability = NarrationAvailabilityMonitor(
            connectivity: monitor,
            status: RemoteNarrationStatusService(client: http, baseURL: configuration.apiBaseURL),
            audio: audioArbiter,
            haptics: hapticSettings
        )
        // Retirar el consentimiento corta la solicitud en vuelo y las actualizaciones.
        consent.onRevoked = { [weak narration] in narration?.cancel() }
        environmentNarration = narration
        let voice = VoiceCommandService(
            listener: DeviceSpeechListener(),
            permissions: PermissionsVoiceGate(permissions: permissionsViewModel),
            audio: ArbiterVoiceAudio(arbiter: audioArbiter),
            // SCRUM-313: el destino dictado se busca y se confirma antes de calcular la ruta.
            lookup: MapKitDestinationLookup(location: location)
        )
        // Una alerta crítica que empieza a sonar corta la escucha (no compite con ella) y
        // vibra siempre, aunque la vibración esté desactivada.
        audioArbiter.onMessageChanged = { [weak voice, weak hapticSettings] message in
            voice?.audioMessageChanged(message)
            hapticSettings?.audioMessageChanged(message)
        }
        self.voiceCommands = voice
        // Pantalla principal: solo lee estados locales (no pide permisos ni usa la red).
        self.homeStatus = HomeStatusService(
            session: session,
            permissions: permissionService,
            safetyModel: BundleSafetyModelChecker(),
            routes: store,
            arbiter: audioArbiter,
            preferences: accessibility
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
