#if canImport(SwiftUI)
import SwiftUI

/// SCRUM-324, Preferencias > Narración del entorno. Explica qué se envía y deja aceptar,
/// no aceptar o retirar el consentimiento. Sin VoiceOver el aviso lo lee el AudioArbiter al
/// entrar; con VoiceOver el foco va a la explicación para no hablar a la vez. Cada resultado
/// lo locuta el servicio.
struct NarrationConsentView: View {
    @ObservedObject var service: NarrationConsentService

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AccessibilityFocusState private var focusesExplanation: Bool
    @State private var confirmsRevocation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                LumioStatusBanner(statusKind, title: statusTitle, message: statusMessage)
                    .accessibilityElement(children: .combine)
                explanation
                actions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(LumioColor.background.ignoresSafeArea())
        .navigationTitle("Narración del entorno")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear(perform: explainOnArrival)
        .confirmationDialog(
            "¿Retirar el consentimiento?",
            isPresented: $confirmsRevocation,
            titleVisibility: .visible
        ) {
            Button("Retirar consentimiento", role: .destructive) { service.revoke() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Lumio dejará de enviar fotos y la narración del entorno quedará desactivada.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            LumioIconBadge(systemName: "camera.viewfinder")
            VStack(alignment: .leading, spacing: 6) {
                Text("Fotos para narrar el entorno")
                    .font(.title2.bold())
                    .foregroundStyle(LumioColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Tú decides si se envían.")
                    .font(.subheadline)
                    .foregroundStyle(LumioColor.textSecondary)
            }
        }
    }

    private var explanation: some View {
        Text(NarrationConsentPolicy.explanation)
            .foregroundStyle(LumioColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .lumioCard()
            .accessibilityFocused($focusesExplanation)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            if service.status == .granted {
                Button {
                    confirmsRevocation = true
                } label: {
                    Label("Retirar consentimiento", systemImage: "hand.raised")
                }
                .buttonStyle(LumioDestructiveButtonStyle())
                .accessibilityHint("Pide confirmación. Después Lumio deja de enviar fotos.")
            } else {
                Button {
                    service.accept()
                } label: {
                    Label("Acepto el envío de fotos", systemImage: "checkmark")
                }
                .buttonStyle(LumioPrimaryButtonStyle())
                .accessibilityHint("Activa la narración del entorno. Puedes retirarlo cuando quieras.")

                if service.status != .declined {
                    Button("No acepto") { service.decline() }
                        .buttonStyle(LumioSecondaryButtonStyle())
                        .accessibilityHint("No se envía ninguna foto. La detección de obstáculos y la navegación siguen igual.")
                }
            }

            Button {
                service.explain()
            } label: {
                Label("Escuchar explicación", systemImage: "speaker.wave.2")
            }
            .buttonStyle(LumioSecondaryButtonStyle())
            .accessibilityHint("Lee en voz alta qué se envía y quién lo recibe.")
        }
    }

    private var statusKind: LumioStatus {
        switch service.status {
        case .granted: return .success
        case .declined: return .error
        case .notAsked, .outdated: return .warning
        }
    }

    private var statusTitle: String {
        switch service.status {
        case .granted: return "Consentimiento dado"
        case .declined: return "Sin consentimiento"
        case .notAsked: return "Aún no has decidido"
        case .outdated: return "El aviso cambió"
        }
    }

    private var statusMessage: String {
        switch service.status {
        case .granted: return "La narración del entorno puede enviar fotos de la cámara."
        case .declined: return "No se envía ninguna foto. La narración del entorno está desactivada."
        case .notAsked: return "Mientras no aceptes, no se envía ninguna foto."
        case .outdated: return "Vuelve a leer el aviso. Mientras no aceptes de nuevo, no se envía ninguna foto."
        }
    }

    private func explainOnArrival() {
        guard service.status != .granted else { return }
        if voiceOverEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { focusesExplanation = true }
        } else {
            service.explain()
        }
    }
}
#endif
