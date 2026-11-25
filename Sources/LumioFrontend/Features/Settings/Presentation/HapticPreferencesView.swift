#if canImport(SwiftUI)
import SwiftUI

/// Configurar Retroalimentación Háptica, en Preferencias > Vibración. Activa o desactiva la
/// vibración, elige qué eventos vibran y con qué intensidad. Cada cambio se aplica en el acto;
/// al encender un evento o cambiar la intensidad se siente un ejemplo.
///
/// VoiceOver: interruptores y selector con etiqueta, valor e indicación; cada evento describe
/// su patrón. Las alertas de seguridad se muestran como siempre activas, sin interruptor.
struct HapticPreferencesView: View {
    @StateObject private var model: HapticPreferencesViewModel

    init(service: any HapticPreferencesManaging) {
        _model = StateObject(wrappedValue: HapticPreferencesViewModel(service: service))
    }

    var body: some View {
        Form {
            Section {
                Text(model.summary)
                    .foregroundStyle(LumioColor.textPrimary)
                    .accessibilityLabel("Preferencias actuales. \(model.summary)")
                if !model.supportsHaptics {
                    LumioStatusBanner(.warning, message: HapticPreferencesAnnouncements.unsupported)
                }
                if let banner = model.banner {
                    LumioStatusBanner(
                        banner.kind == .error ? .error : .warning,
                        title: banner.title, message: banner.message
                    )
                }
                Toggle("Vibración", isOn: Binding(get: { model.preferences.isEnabled }, set: { model.setEnabled($0) }))
                    .accessibilityHint("Activa o desactiva la vibración de los eventos de la ruta. Las alertas de seguridad siempre vibran.")
            }

            Section {
                ForEach(HapticCue.configurable, id: \.self) { cue in
                    Toggle(isOn: Binding(get: { model.isOn(cue) }, set: { model.setCue(cue, on: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cue.name)
                            Text(cue.patternDescription)
                                .font(.footnote)
                                .foregroundStyle(LumioColor.textSecondary)
                        }
                    }
                    .accessibilityHint("\(cue.patternDescription) Al activarlo se siente el patrón.")
                    .accessibilityAction(named: "Probar vibración") { model.preview(cue) }
                }
            } header: {
                Text("Eventos")
            } footer: {
                Text("Con VoiceOver, usa el rotor de acciones en cada evento para probar su vibración.")
            }
            .disabled(!model.preferences.isEnabled)

            Section {
                Picker(
                    "Intensidad",
                    selection: Binding(get: { model.preferences.intensity }, set: { model.setIntensity($0) })
                ) {
                    ForEach(HapticIntensity.allCases) { intensity in
                        Text(intensity.name).tag(intensity)
                    }
                }
                .accessibilityHint("Cambia la fuerza de la vibración de los eventos. Al cambiarla se siente un ejemplo.")
            } header: {
                Text("Intensidad")
            }
            .disabled(!model.preferences.isEnabled)

            Section {
                ForEach(HapticCue.alwaysOn, id: \.self) { cue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cue.name)
                        Text(cue.patternDescription)
                            .font(.footnote)
                            .foregroundStyle(LumioColor.textSecondary)
                        Text("Siempre activa")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(LumioColor.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: "Probar vibración") { model.preview(cue) }
                }

                Button {
                    model.preview(.criticalAlert)
                } label: {
                    Label("Probar alerta de seguridad", systemImage: "exclamationmark.triangle")
                }
            } header: {
                Text("Alertas de seguridad")
            } footer: {
                Text(HapticPreferencesAnnouncements.criticalAlwaysOn)
            }
        }
        .navigationTitle("Vibración")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { model.load() }
    }
}
#endif
