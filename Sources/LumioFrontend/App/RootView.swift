#if canImport(SwiftUI)
import SwiftUI

struct RootView: View {
    let routeCreator: any RouteCreating
    let destinationSuggester: any DestinationSuggesting
    let authenticationService: any Authenticating
    /// Se decide antes del primer frame para no mostrar la bienvenida de forma transitoria.
    @State private var entry: AppEntry

    init(
        sessionService: any SessionRestoring,
        authenticationService: any Authenticating,
        routeCreator: any RouteCreating,
        destinationSuggester: any DestinationSuggesting
    ) {
        self.routeCreator = routeCreator
        self.destinationSuggester = destinationSuggester
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
                DestinationView(routeCreator: routeCreator, suggester: destinationSuggester)
            }
            .tabItem { Label("Trayecto", systemImage: "figure.walk") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Preferencias", systemImage: "gearshape") }
        }
        .tint(LumioColor.actionPrimary)
    }

    /// Mientras no exista autenticación, solo las compilaciones DEBUG pueden llegar al inicio.
    private var developmentBypass: (() -> Void)? {
        #if DEBUG
        return { entry = .home }
        #else
        return nil
        #endif
    }
}
#endif
