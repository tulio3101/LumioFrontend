#if os(iOS)
import UIKit

/// Háptica de resultado: éxito al tener la ruta lista o al terminar la navegación, error si
/// no se pudo crear.
@MainActor
final class UIKitHapticFeedback: HapticFeedbackPlaying {
    private let generator = UINotificationFeedbackGenerator()

    func play(_ cue: HapticCue) {
        switch cue {
        case .routeReady:
            generator.notificationOccurred(.success)
        case .routeFailed:
            generator.notificationOccurred(.error)
        case .routeFinished:
            generator.notificationOccurred(.success)
        case .emergencyActivated:
            // Distinto de éxito y de error: avisa que empezó el margen para cancelar.
            generator.notificationOccurred(.warning)
        case .emergencySent:
            generator.notificationOccurred(.success)
        case .emergencyFailed:
            generator.notificationOccurred(.error)
        }
    }
}
#endif
