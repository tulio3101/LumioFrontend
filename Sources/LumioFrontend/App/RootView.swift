#if canImport(SwiftUI)
import SwiftUI

struct RootView: View {
    let routeCreator: any RouteCreating
    let routeModifier: any RouteModifying
    let instructionRepeater: any InstructionRepeating
    let destinationSuggester: any DestinationSuggesting
    let authenticationService: any Authenticating
    let signOut: any SigningOut
    /// Se decide antes del primer frame para no mostrar la bienvenida de forma transitoria.
    @State private var entry: AppEntry

    init(
        sessionService: any SessionRestoring,
        authenticationService: any Authenticating,
        routeCreator: any RouteCreating,
        routeModifier: any RouteModifying,
        instructionRepeater: any InstructionRepeating,
        destinationSuggester: any DestinationSuggesting,
        signOut: any SigningOut
    ) {
        self.routeCreator = routeCreator
        self.routeModifier = routeModifier
        self.instructionRepeater = instructionRepeater
        self.destinationSuggester = destinationSuggester
        self.signOut = signOut
        self.authenticationService = authenticationService
        _entry = State(initialValue: AppEntry(session: sessionService))
    }

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
                    suggester: destinationSuggester
                )
            }
            .tabItem { Label("Trayecto", systemImage: "figure.walk") }

            NavigationStack {
                SettingsView(signOut: signOut) { entry = .welcome }
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
