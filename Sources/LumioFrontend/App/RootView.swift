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
    let destinationSuggester: any DestinationSuggesting
    let authenticationService: any Authenticating
    let signOut: any SigningOut
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
        destinationSuggester: any DestinationSuggesting,
        signOut: any SigningOut,
        permissions: PermissionsViewModel
    ) {
        self.routeCreator = routeCreator
        self.routeModifier = routeModifier
        self.instructionRepeater = instructionRepeater
        self.routeStatus = routeStatus
        self.recentRoutes = recentRoutes
        self.routeFinisher = routeFinisher
        self.arrivalMonitor = arrivalMonitor
        self.destinationSuggester = destinationSuggester
        self.signOut = signOut
        self.authenticationService = authenticationService
        self.permissions = permissions
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
        destinationSuggester: any DestinationSuggesting,
        signOut: any SigningOut
    ) {
        self.routeCreator = routeCreator
        self.routeModifier = routeModifier
        self.instructionRepeater = instructionRepeater
        self.routeStatus = routeStatus
        self.recentRoutes = recentRoutes
        self.routeFinisher = routeFinisher
        self.arrivalMonitor = arrivalMonitor
        self.destinationSuggester = destinationSuggester
        self.signOut = signOut
        self.authenticationService = authenticationService
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
                    suggester: destinationSuggester
                )
            }
            .tabItem { Label("Trayecto", systemImage: "figure.walk") }

            NavigationStack {
                #if os(iOS)
                SettingsView(signOut: signOut, onSignedOut: { entry = .welcome }, permissions: permissions)
                #else
                SettingsView(signOut: signOut) { entry = .welcome }
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
