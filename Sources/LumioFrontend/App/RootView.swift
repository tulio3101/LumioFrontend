#if canImport(SwiftUI)
import SwiftUI

struct RootView: View {
    let routeCreator: any RouteCreating
    let routeModifier: any RouteModifying
    let instructionRepeater: any InstructionRepeating
    let routeStatus: any RouteStatusQuerying
    let recentRoutes: any RecentRoutesQuerying
    let routeFinisher: any RouteFinishing
    let arrivalMonitor: any ArrivalMonitoring
    let deviationMonitor: any RouteDeviationMonitoring
    let destinationSuggester: any DestinationSuggesting
    let authenticationService: any Authenticating
    let signOut: any SigningOut
    let profile: any ProfileManaging
    let contacts: any TrustedContactsManaging
    /// Botón de Emergencia (SCRUM-35): fijo sobre la pestaña Trayecto y sus pantallas.
    let emergency: any EmergencyManaging
    let accountDeleter: any AccountDeleting
    /// Configurar Preferencias de Voz Descriptiva (Preferencias > Preferencias de voz).
    let voicePreferences: any VoicePreferencesManaging
    /// Configurar Retroalimentación Háptica (Preferencias > Vibración).
    let hapticPreferences: any HapticPreferencesManaging
    /// SCRUM-33: detección de obstáculos y su compuerta de permiso de cámara. nil fuera de iOS
    /// o si el modelo YOLO no cargó. Se pasa a DestinationView para arrancarla con la ruta.
    let safetyMonitor: (any SafetyMonitoring)?
    let obstacleGate: (any CameraAssistanceGating)?
    /// HU Interactuar mediante voz: botón «Comando de voz» en Trayecto. nil fuera de iOS.
    let voiceCommands: VoiceCommandService?
    /// Se decide antes del primer frame para no mostrar la bienvenida de forma transitoria.
    @State private var entry: AppEntry

    #if os(iOS)
    /// SCRUM-315: permisos accesibles (micrófono, voz, ubicación, cámara) para el destino por
    /// voz y la detección de obstáculos. Se comparte con DestinationView y SettingsView.
    let permissions: PermissionsViewModel

    init(
        sessionService: any SessionRestoring,
        authenticationService: any Authenticating,
        routeCreator: any RouteCreating,
        routeModifier: any RouteModifying,
        instructionRepeater: any InstructionRepeating,
        routeStatus: any RouteStatusQuerying,
        recentRoutes: any RecentRoutesQuerying,
        routeFinisher: any RouteFinishing,
        arrivalMonitor: any ArrivalMonitoring,
        deviationMonitor: any RouteDeviationMonitoring,
        destinationSuggester: any DestinationSuggesting,
        signOut: any SigningOut,
        profile: any ProfileManaging,
        contacts: any TrustedContactsManaging,
        emergency: any EmergencyManaging,
        accountDeleter: any AccountDeleting,
        voicePreferences: any VoicePreferencesManaging,
        hapticPreferences: any HapticPreferencesManaging,
        permissions: PermissionsViewModel,
        safetyMonitor: (any SafetyMonitoring)? = nil,
        obstacleGate: (any CameraAssistanceGating)? = nil,
        voiceCommands: VoiceCommandService? = nil
    ) {
        self.routeCreator = routeCreator
        self.routeModifier = routeModifier
        self.instructionRepeater = instructionRepeater
        self.routeStatus = routeStatus
        self.recentRoutes = recentRoutes
        self.routeFinisher = routeFinisher
        self.arrivalMonitor = arrivalMonitor
        self.deviationMonitor = deviationMonitor
        self.destinationSuggester = destinationSuggester
        self.signOut = signOut
        self.profile = profile
        self.contacts = contacts
        self.emergency = emergency
        self.accountDeleter = accountDeleter
        self.voicePreferences = voicePreferences
        self.hapticPreferences = hapticPreferences
        self.authenticationService = authenticationService
        self.permissions = permissions
        self.safetyMonitor = safetyMonitor
        self.obstacleGate = obstacleGate
        self.voiceCommands = voiceCommands
        _entry = State(initialValue: AppEntry(session: sessionService))
    }
    #else
    init(
        sessionService: any SessionRestoring,
        authenticationService: any Authenticating,
        routeCreator: any RouteCreating,
        routeModifier: any RouteModifying,
        instructionRepeater: any InstructionRepeating,
        routeStatus: any RouteStatusQuerying,
        recentRoutes: any RecentRoutesQuerying,
        routeFinisher: any RouteFinishing,
        arrivalMonitor: any ArrivalMonitoring,
        deviationMonitor: any RouteDeviationMonitoring,
        destinationSuggester: any DestinationSuggesting,
        signOut: any SigningOut,
        profile: any ProfileManaging,
        contacts: any TrustedContactsManaging,
        emergency: any EmergencyManaging,
        accountDeleter: any AccountDeleting,
        voicePreferences: any VoicePreferencesManaging,
        hapticPreferences: any HapticPreferencesManaging,
        safetyMonitor: (any SafetyMonitoring)? = nil,
        obstacleGate: (any CameraAssistanceGating)? = nil,
        voiceCommands: VoiceCommandService? = nil
    ) {
        self.routeCreator = routeCreator
        self.routeModifier = routeModifier
        self.instructionRepeater = instructionRepeater
        self.routeStatus = routeStatus
        self.recentRoutes = recentRoutes
        self.routeFinisher = routeFinisher
        self.arrivalMonitor = arrivalMonitor
        self.deviationMonitor = deviationMonitor
        self.destinationSuggester = destinationSuggester
        self.signOut = signOut
        self.profile = profile
        self.contacts = contacts
        self.emergency = emergency
        self.accountDeleter = accountDeleter
        self.voicePreferences = voicePreferences
        self.hapticPreferences = hapticPreferences
        self.authenticationService = authenticationService
        self.safetyMonitor = safetyMonitor
        self.obstacleGate = obstacleGate
        self.voiceCommands = voiceCommands
        _entry = State(initialValue: AppEntry(session: sessionService))
    }
    #endif

    var body: some View {
        switch entry {
        case .welcome:
            WelcomeView(
                authenticationService: authenticationService,
                onAuthenticated: { entry = .home },
                continueWithoutSession: developmentBypass
            )
        case .home:
            home
        }
    }

    private var home: some View {
        TabView {
            NavigationStack {
                DestinationView(
                    routeCreator: routeCreator,
                    routeModifier: routeModifier,
                    instructionRepeater: instructionRepeater,
                    routeStatusQuery: routeStatus,
                    recentRoutes: recentRoutes,
                    routeFinisher: routeFinisher,
                    arrivalMonitor: arrivalMonitor,
                    deviationMonitor: deviationMonitor,
                    suggester: destinationSuggester,
                    safetyMonitor: safetyMonitor,
                    obstacleGate: obstacleGate,
                    voiceCommands: voiceCommands
                )
            }
            // Fijo en la pila de Trayecto: sigue visible al abrir la ruta activa.
            .emergencyControl(emergency, onSessionExpired: { entry = .welcome })
            .tabItem { Label("Trayecto", systemImage: "figure.walk") }

            NavigationStack {
                #if os(iOS)
                SettingsView(
                    signOut: signOut, profile: profile, contacts: contacts, accountDeleter: accountDeleter,
                    voicePreferences: voicePreferences, hapticPreferences: hapticPreferences,
                    onSignedOut: { entry = .welcome }, permissions: permissions
                )
                #else
                SettingsView(
                    signOut: signOut, profile: profile, contacts: contacts, accountDeleter: accountDeleter,
                    voicePreferences: voicePreferences, hapticPreferences: hapticPreferences
                ) { entry = .welcome }
                #endif
            }
            .tabItem { Label("Preferencias", systemImage: "gearshape") }
        }
        .tint(LumioColor.actionPrimary)
    }

    /// Solo DEBUG: entrar sin sesión si el backend no está disponible. Las rutas se calculan
    /// pero quedan pendientes de guardar en el servidor.
    private var developmentBypass: (() -> Void)? {
        #if DEBUG
        return { entry = .home }
        #else
        return nil
        #endif
    }
}
#endif
