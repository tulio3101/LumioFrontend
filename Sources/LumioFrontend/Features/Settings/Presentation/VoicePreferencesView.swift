#if canImport(SwiftUI)
import SwiftUI

/// Configurar Preferencias de Voz Descriptiva, en Preferencias > Preferencias de voz.
/// Muestra el idioma, la voz y la velocidad actuales y permite cambiarlos. Cada cambio se
/// aplica en el acto a todo lo que dice Lumio y se confirma por audio con la voz nueva.
///
/// VoiceOver: el resumen se lee como un solo elemento; la velocidad es un control ajustable
/// (deslizar hacia arriba o hacia abajo) que dice su valor. Los resultados también aparecen
/// en un aviso, sin mover el foco, para no superponer VoiceOver con la voz de Lumio.
struct VoicePreferencesView: View {
    @StateObject private var model: VoicePreferencesViewModel

    init(service: any VoicePreferencesManaging) {
        _model = StateObject(wrappedValue: VoicePreferencesViewModel(service: service))
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Así habla Lumio ahora")
                        .font(.headline)
                        .foregroundStyle(LumioColor.textPrimary)
                    Text(model.summary)
                        .font(.body)
                        .foregroundStyle(LumioColor.textPrimary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Preferencias actuales. \(model.summary)")

                if let banner = model.banner {
                    LumioStatusBanner(status(for: banner.kind), title: banner.title, message: banner.message)
                }
            } footer: {
                Text(VoicePreferencesAnnouncements.appliesToEverything)
            }

            Section {
                if model.languages.isEmpty {
                    Text("Este teléfono no informó voces en español. Lumio usa la voz más cercana disponible.")
                        .foregroundStyle(LumioColor.textSecondary)
                } else {
                    Picker("Idioma", selection: languageSelection) {
                        ForEach(model.languages) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    .accessibilityHint("Cambia el acento de la voz. Al cambiarlo se usa la voz predeterminada de ese idioma.")
                }
            } header: {
                Text("Idioma")
            }

            Section {
                Picker("Voz", selection: voiceSelection) {
                    Text("Predeterminada").tag(String?.none)
                    ForEach(model.voices) { voice in
                        Text(voice.displayName).tag(Optional(voice.id))
                    }
                }
                .accessibilityHint("Elige entre las voces instaladas para este idioma.")
            } header: {
                Text("Voz")
            } footer: {
                Text("Para más voces, descárgalas en Ajustes, Accesibilidad, Contenido leído, Voces.")
            }

            Section {
                Stepper {
                    HStack {
                        Text("Velocidad")
                        Spacer()
                        Text(model.rateName.capitalizedFirst)
                            .foregroundStyle(LumioColor.textSecondary)
                    }
                } onIncrement: {
                    if model.canSpeedUp { model.speedUp() }
                } onDecrement: {
                    if model.canSlowDown { model.slowDown() }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Velocidad")
                .accessibilityValue(model.rateName)
                .accessibilityHint(
                    "Desliza hacia arriba para hablar más rápido o hacia abajo para más lento. "
                    + "Va de \(SpeechRatePolicy.decimal(SpeechRatePolicy.range.lowerBound)) a "
                    + "\(SpeechRatePolicy.decimal(SpeechRatePolicy.range.upperBound)) veces la normal."
                )
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: if model.canSpeedUp { model.speedUp() }
                    case .decrement: if model.canSlowDown { model.slowDown() }
                    @unknown default: break
                    }
                }

                Button {
                    model.setRate(VoicePreferences.standard.speechRate)
                } label: {
                    Label("Volver a la velocidad normal", systemImage: "arrow.uturn.backward")
                }
                .disabled(model.preferences.speechRate == VoicePreferences.standard.speechRate)
            } header: {
                Text("Velocidad")
            }

            Section {
                Button {
                    model.preview()
                } label: {
                    Label("Probar la voz", systemImage: "play.circle")
                }
                .accessibilityHint("Lumio dice una frase de ejemplo con esta configuración.")
            }
        }
        .navigationTitle("Preferencias de voz")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { model.load() }
    }

    private var languageSelection: Binding<String> {
        Binding(get: { model.preferences.language }, set: { model.selectLanguage($0) })
    }

    private var voiceSelection: Binding<String?> {
        Binding(get: { model.preferences.voiceIdentifier }, set: { model.selectVoice($0) })
    }

    private func status(for kind: VoicePreferencesViewModel.Banner.Kind) -> LumioStatus {
        switch kind {
        case .success: .success
        case .warning: .warning
        case .error: .error
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
#endif
