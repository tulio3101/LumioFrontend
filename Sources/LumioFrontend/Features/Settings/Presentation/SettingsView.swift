#if canImport(SwiftUI)
import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            FeatureStatusView(
                title: "Preferencias de voz",
                message: "Aquí se integrarán idioma, velocidad y configuración de voz."
            )
        }
        .navigationTitle("Preferencias")
    }
}
#endif
