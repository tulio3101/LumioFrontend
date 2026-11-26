#if os(iOS)
import SwiftUI
import UIKit

struct PermissionsView: View {
    @ObservedObject var model: PermissionsViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AccessibilityFocusState private var explanationFocused: Bool

    var body: some View {
        List {
            Section {
                Text("Para indicar el destino por voz necesitas micrófono y reconocimiento de voz. Para calcular la ruta necesitas ubicación. La cámara permite detectar obstáculos. Las notificaciones son opcionales.")
                Button("Escuchar permisos necesarios") {
                    Task { await model.say("Para indicar el destino por voz necesitas micrófono y reconocimiento de voz. Para calcular la ruta necesitas ubicación. Para detectar obstáculos necesitas cámara. Las notificaciones son opcionales.") }
                }
                .disabled(model.isSpeaking)
            }
            Section("Permisos del dispositivo") {
                ForEach(AppPermission.allCases) { permission in
                    VStack(alignment: .leading, spacing: 8) {
                        // SCRUM-29: nombre, estado y para qué sirve se leen juntos, como
                        // encabezado de la fila; los botones siguen siendo elementos propios.
                        VStack(alignment: .leading, spacing: 8) {
                            Text(permission.title).font(.headline)
                            Text((model.statuses[permission] ?? .notDetermined).label)
                            Text(permission.purpose)
                            if permission == .notifications {
                                Text("Se solicitarán cuando una función las necesite. Actualmente ninguna función conectada las requiere.")
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        Button("Escuchar estado de \(permission.title)") {
                            Task { await model.say(model.feedback(for: permission)) }
                        }
                        .disabled(model.isSpeaking)
                        if model.statuses[permission] == .notDetermined && permission != .notifications {
                            Button("Configurar \(permission.title)") { Task { await model.prepare(permission) } }
                                .disabled(model.isSpeaking || model.isRequesting)
                        }
                        if model.statuses[permission] == .denied || model.statuses[permission] == .unavailable {
                            Button("Abrir Ajustes para \(permission.title)") { openSettings() }
                        }
                    }
                }
            }
            if !model.message.isEmpty {
                Section("Último mensaje") {
                    Text(model.message)
                        // SCRUM-29: el mensaje cambia tras cada acción; VoiceOver lo relee.
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
        // List usa estilo automático: varios botones de una fila pueden activarse juntos.
        // Cada acción debe responder únicamente al botón que el usuario activa.
        .buttonStyle(.borderless)
        .navigationTitle("Permisos")
        .task { await model.refresh() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await model.refresh() } }
        }
        .sheet(item: $model.selected) { permission in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(permission.title).font(.title).accessibilityAddTraits(.isHeader)
                        Text(permission.purpose + " " + permission.limitation)
                            .accessibilityFocused($explanationFocused)
                        Text("iOS mostrará una solicitud. Con VoiceOver, desliza para recorrer sus opciones y toca dos veces para elegir. Puedes rechazar el permiso.")
                        if model.isSpeaking { Text("Reproduciendo explicación…") }
                        Button("Repetir explicación") { Task { await model.explain(permission) } }
                            .disabled(model.isSpeaking || model.isRequesting)
                        Button("Continuar con \(permission.title)") { Task { await model.requestSelected() } }
                            .disabled(model.isSpeaking || model.isRequesting)
                        Button("Ahora no") { model.selected = nil }
                            .disabled(model.isRequesting)
                    }
                    .padding()
                }
                .navigationTitle("Antes de continuar")
                .interactiveDismissDisabled(model.isRequesting)
                .task {
                    // VoiceOver lee el contenido enfocado; no lanzar otra voz simultánea.
                    if UIAccessibility.isVoiceOverRunning {
                        explanationFocused = true
                    } else {
                        await model.explain(permission)
                    }
                }
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
#endif
