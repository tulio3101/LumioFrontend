#if canImport(SwiftUI)
import SwiftUI

struct RootView: View {
    let navigationService: any NavigationPlanning

    #if os(iOS)
    let permissions: PermissionsViewModel
    #endif

    var body: some View {
        TabView {
            NavigationStack {
                #if os(iOS)
                DestinationView(service: navigationService, permissions: permissions)
                #else
                DestinationView(service: navigationService)
                #endif
            }
            .tabItem { Label("Trayecto", systemImage: "location") }

            NavigationStack {
                #if os(iOS)
                SettingsView(permissions: permissions)
                #else
                SettingsView()
                #endif
            }
            .tabItem { Label("Preferencias", systemImage: "gearshape") }
        }
    }
}
#endif
