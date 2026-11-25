#if canImport(SwiftUI)
import SwiftUI

/// Estado del control de emergencia. Toda la lógica, el audio y la háptica son de
/// EmergencyService; aquí solo se decide qué muestra y qué hace el botón principal en cada fase.
@MainActor
final class EmergencyViewModel: ObservableObject {
    /// Lo que hace el botón principal. Es siempre el mismo botón, para que el foco de VoiceOver
    /// no se pierda al pasar de «Emergencia» a «Cancelar» y a «Reintentar».
    enum PrimaryAction: Equatable {
        case activate
        case cancel
        case retry
        case none
    }

    @Published private(set) var phase: EmergencyPhase

    private let service: any EmergencyManaging
    private let onSessionExpired: () -> Void

    init(service: any EmergencyManaging, onSessionExpired: @escaping () -> Void) {
        self.service = service
        self.onSessionExpired = onSessionExpired
        phase = service.phase
        service.onPhaseChange = { [weak self] phase in self?.phase = phase }
    }

    var primaryAction: PrimaryAction {
        switch phase {
        case .idle, .sent, .cancelled: .activate
        case .countingDown: .cancel
        case .sending: .none
        case .failed(let failure): failure.canRetry ? .retry : .activate
        }
    }

    var primaryTitle: String {
        switch phase {
        case .countingDown(let seconds): "Cancelar alerta (\(seconds))"
        case .sending: "Enviando alerta…"
        case .failed(let failure) where failure.canRetry: "Reintentar envío"
        default: "Emergencia"
        }
    }

    var primarySymbol: String {
        switch primaryAction {
        case .activate: "exclamationmark.triangle.fill"
        case .cancel: "xmark.circle.fill"
        case .retry: "arrow.clockwise"
        case .none: "paperplane.fill"
        }
    }

    var primaryHint: String {
        switch primaryAction {
        case .activate:
            "Avisa por correo a tus contactos de confianza con tu ubicación. Tendrás "
                + "\(EmergencyService.countdownSeconds) segundos para cancelar. "
                + EmergencyAnnouncements.disclaimer
        case .cancel: "Detiene la alerta: no se envía nada."
        case .retry: "Vuelve a enviar la misma alerta, sin esperar de nuevo."
        case .none: "La alerta se está enviando."
        }
    }

    /// Se puede cerrar el resultado, pero nunca una alerta en curso.
    var canDismiss: Bool { !phase.isBusy && phase != .idle }

    var banner: (status: LumioStatus, title: String, message: String)? {
        guard let message = EmergencyAnnouncements.message(for: phase) else { return nil }
        switch phase {
        case .idle:
            return nil
        case .countingDown:
            return (.warning, "Alerta de emergencia en camino", message)
        case .sending:
            return (.warning, "Enviando alerta", message)
        case .sent(let delivery):
            return (delivery.reachedEveryone ? .success : .warning, "Alerta enviada", message)
        case .failed:
            return (.error, "No se envió la alerta", message)
        case .cancelled:
            return (.warning, "Alerta cancelada", message)
        }
    }

    func performPrimaryAction() {
        switch primaryAction {
        case .activate: service.activate()
        case .cancel: service.cancel()
        case .retry: service.retry()
        case .none: break
        }
    }

    func dismiss() {
        let expired = phase == .failed(.sessionExpired)
        service.dismiss()
        // La sesión ya se borró: al cerrar el aviso se vuelve a iniciar sesión.
        if expired { onSessionExpired() }
    }
}
#endif
