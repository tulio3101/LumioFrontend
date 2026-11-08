#if os(iOS)
import UIKit

/// Háptica de resultado: éxito al tener la ruta lista, error si no se pudo crear.
@MainActor
final class UIKitHapticFeedback: HapticFeedbackPlaying {
    private let generator = UINotificationFeedbackGenerator()

    func play(_ cue: HapticCue) {
        switch cue {
        case .routeReady:
            generator.notificationOccurred(.success)
        case .routeFailed:
            generator.notificationOccurred(.error)
        }
    }
}
#endif
