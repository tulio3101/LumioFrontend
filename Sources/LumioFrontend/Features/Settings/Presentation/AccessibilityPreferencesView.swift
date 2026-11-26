#if canImport(SwiftUI)
import SwiftUI

/// SCRUM-32, Preferencias > Preferencias de accesibilidad. Controles nativos de iOS (Toggle y
/// Picker), que VoiceOver lee con su nombre, su valor y cómo cambiarlo. Cada cambio se aplica y
/// se guarda al instante; si no se pudo guardar, el servicio lo dice por audio.
struct AccessibilityPreferencesView: View {
    @ObservedObject var service: AccessibilityPreferencesService

    var body: some View {
        Form {
            if service.storedUnreadable {
                Section {
                    LumioStatusBanner(.warning, message: AccessibilityPreferencesAnnouncements.unreadable)
                }
            }
            Section {
                Toggle("Narración automática", isOn: binding(\.autoNarration))
                    .accessibilityHint("Durante la ruta, describe el entorno cuando cambia lo que tienes delante. Puedes seguir pidiendo descripciones a mano.")
            } header: {
                Text("Narración del entorno")
            } footer: {
                Text("Necesita tu consentimiento para enviar fotos (Preferencias, Narración del entorno).")
            }
            Section {
                Toggle("Decir el estado al abrir la app", isOn: binding(\.announceStatusOnLaunch))
                    .accessibilityHint("Al abrir Lumio dice si hay sesión, permisos, detección y ruta activa.")
                Picker("Avisos", selection: binding(\.announcementDetail)) {
                    ForEach(AnnouncementDetail.allCases) { detail in
                        Text(detail.name).tag(detail)
                    }
                }
                .accessibilityHint(service.preferences.announcementDetail.explanation)
            } header: {
                Text("Avisos")
            } footer: {
                Text(service.preferences.announcementDetail.explanation)
            }
        }
        .navigationTitle("Preferencias de accesibilidad")
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AccessibilityPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { service.preferences[keyPath: keyPath] },
            set: { value in
                var updated = service.preferences
                updated[keyPath: keyPath] = value
                service.update(updated)
            }
        )
    }
}
#endif
