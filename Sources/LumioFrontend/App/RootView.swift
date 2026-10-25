#if canImport(SwiftUI)
import SwiftUI

struct RootView: View {
    let navigationService: any NavigationPlanning

    var body: some View {
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
}
#endif
