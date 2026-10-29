#if canImport(SwiftUI)
import SwiftUI

struct RootView: View {
    let navigationService: any NavigationPlanning
    let authenticationService: any Authenticating
    /// Se decide antes del primer frame para no mostrar la bienvenida de forma transitoria.
    @State private var entry: AppEntry

    init(
        sessionService: any SessionRestoring,
        authenticationService: any Authenticating,
        navigationService: any NavigationPlanning
    ) {
        self.navigationService = navigationService
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
                DestinationView(service: navigationService)
            }
            .tabItem { Label("Trayecto", systemImage: "location") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Preferencias", systemImage: "gearshape") }
        }
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
