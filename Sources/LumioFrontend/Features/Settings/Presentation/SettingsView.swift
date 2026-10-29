#if canImport(SwiftUI)
import SwiftUI

struct SettingsView: View {
    #if os(iOS)
    let permissions: PermissionsViewModel
    #endif

    var body: some View {
        Form {
            #if os(iOS)
            NavigationLink("Permisos y accesibilidad") { PermissionsView(model: permissions) }
            #endif
            FeatureStatusView(
                title: "Preferencias de voz",
                message: "Aquí se integrarán idioma, velocidad y configuración de voz."
            )
        }
        .navigationTitle("Preferencias")
    }
}
#endif
