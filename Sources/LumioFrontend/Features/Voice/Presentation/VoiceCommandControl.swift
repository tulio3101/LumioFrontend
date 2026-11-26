#if canImport(SwiftUI)
import SwiftUI

extension View {
    /// Añade el botón flotante «Comando de voz» y el aviso «Escuchando». Sin servicio de voz
    /// (otras plataformas o pruebas) la vista no cambia.
    @ViewBuilder
    func voiceCommandControl(_ voice: VoiceCommandService?) -> some View {
        if let voice {
            modifier(VoiceCommandControl(voice: voice))
        } else {
            self
        }
    }
}

private struct VoiceCommandControl: ViewModifier {
    @ObservedObject var voice: VoiceCommandService

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(alignment: .bottom, spacing: 12) {
                if voice.phase == .listening {
                    VoiceListeningBanner()
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                VoiceCommandButton(voice: voice)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }
}

/// Botón circular de micrófono. Activa la escucha; si ya escucha, la cierra.
struct VoiceCommandButton: View {
    @ObservedObject var voice: VoiceCommandService

    var body: some View {
        Button {
            voice.toggle()
        } label: {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 64, height: 64)
                .foregroundStyle(LumioColor.onActionPrimary)
                .background(Circle().fill(LumioColor.actionPrimary))
                .overlay {
                    if voice.phase == .listening {
                        Circle().strokeBorder(LumioColor.onActionPrimary, lineWidth: 3).padding(4)
                    }
                }
                .shadow(color: LumioColor.actionPrimary.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityAddTraits(voice.phase == .listening ? .isSelected : [])
    }

    private var symbol: String {
        switch voice.phase {
        case .idle: return "mic.fill"
        case .preparing, .processing: return "waveform"
        case .listening: return "stop.fill"
        }
    }

    private var label: String {
        voice.phase == .idle ? "Comando de voz" : "Cerrar comando de voz"
    }

    private var hint: String {
        switch voice.phase {
        case .idle:
            return "Activa el micrófono para decir un comando. Di ayuda para conocer los comandos."
        case .listening:
            return "Lumio te está escuchando. Activa para cerrar sin hacer nada."
        case .preparing, .processing:
            return "Activa para cancelar el comando."
        }
    }
}

/// Aviso visual de que el micrófono está abierto (también para quien ve la pantalla).
private struct VoiceListeningBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Escuchando…").font(.headline)
            Text("Di un comando o «ayuda».").font(.subheadline)
        }
        .foregroundStyle(LumioColor.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(LumioColor.surface, in: RoundedRectangle(cornerRadius: LumioRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LumioRadius.control, style: .continuous)
                .strokeBorder(LumioColor.controlBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
#endif
