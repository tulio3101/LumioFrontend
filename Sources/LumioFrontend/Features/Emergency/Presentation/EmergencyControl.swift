#if canImport(SwiftUI)
import SwiftUI

extension View {
    /// Añade el botón de emergencia fijo en la parte inferior, sobre la barra de pestañas y
    /// presente en todas las pantallas de la pila (también durante la ruta). Sin servicio
    /// (pruebas u otras plataformas) la vista no cambia.
    @ViewBuilder
    func emergencyControl(_ service: (any EmergencyManaging)?, onSessionExpired: @escaping () -> Void) -> some View {
        if let service {
            modifier(EmergencyControlModifier(service: service, onSessionExpired: onSessionExpired))
        } else {
            self
        }
    }
}

private struct EmergencyControlModifier: ViewModifier {
    @StateObject private var model: EmergencyViewModel

    init(service: any EmergencyManaging, onSessionExpired: @escaping () -> Void) {
        _model = StateObject(wrappedValue: EmergencyViewModel(service: service, onSessionExpired: onSessionExpired))
    }

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            EmergencyControl(model: model)
        }
    }
}

/// Botón de Emergencia (SCRUM-35) y el aviso de su estado.
///
/// Un solo botón principal cambia de «Emergencia» a «Cancelar alerta (n)» y a «Reintentar
/// envío» sin cambiar de identidad, para que el foco de VoiceOver no se pierda: quien activó la
/// emergencia con doble toque puede cancelar con otro doble toque en el mismo lugar. El audio y
/// la háptica los da EmergencyService; el aviso en pantalla es el mismo texto que se locuta,
/// y no se mueve el foco para no superponer VoiceOver con el árbitro de audio.
struct EmergencyControl: View {
    @ObservedObject var model: EmergencyViewModel

    var body: some View {
        VStack(spacing: 10) {
            if let banner = model.banner {
                LumioStatusBanner(banner.status, title: banner.title, message: banner.message)
            }
            primaryButton
            if model.canDismiss {
                Button("Cerrar aviso") { model.dismiss() }
                    .buttonStyle(LumioSecondaryButtonStyle())
            }
            if model.phase == .idle {
                Text(EmergencyAnnouncements.disclaimer)
                    .font(.footnote)
                    .foregroundStyle(LumioColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(LumioColor.background.opacity(0.96))
    }

    @ViewBuilder
    private var primaryButton: some View {
        let button = Button {
            model.performPrimaryAction()
        } label: {
            HStack(spacing: 10) {
                if model.primaryAction == .none {
                    ProgressView()
                } else {
                    Image(systemName: model.primarySymbol)
                }
                Text(model.primaryTitle)
            }
        }
        .disabled(model.primaryAction == .none)
        .accessibilityLabel(model.primaryTitle)
        .accessibilityHint(model.primaryHint)

        switch model.primaryAction {
        case .activate:
            // Rojo con borde, icono y texto: no depende solo del color.
            button.buttonStyle(LumioDestructiveButtonStyle())
        case .cancel, .retry, .none:
            // Cancelar es la acción segura: primaria, no roja.
            button.buttonStyle(LumioPrimaryButtonStyle())
        }
    }
}
#endif
