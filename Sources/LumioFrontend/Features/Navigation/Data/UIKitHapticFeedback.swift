#if os(iOS)
import UIKit
import OSLog

/// Háptica de resultado: éxito al tener la ruta lista o al terminar la navegación, error si
/// no se pudo crear. SCRUM-33: peligro (bajada, 3 impactos fuertes) y aviso (subida u obstáculo
/// cercano, 2 impactos medios).
@MainActor
final class UIKitHapticFeedback: HapticFeedbackPlaying {
    private let generator = UINotificationFeedbackGenerator()
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    #if DEBUG
    private let logger = Logger(subsystem: "com.lumio.app", category: "Haptics")
    #endif

    func play(_ cue: HapticCue) {
        #if DEBUG
        logger.debug("haptic \(String(describing: cue))")
        #endif
        switch cue {
        case .routeReady:
            generator.notificationOccurred(.success)
        case .routeFailed:
            generator.notificationOccurred(.error)
        case .routeFinished:
            generator.notificationOccurred(.success)
        case .danger:
            // Patrón distinguible = 3 impactos fuertes seguidos.
            pulse(heavy, remaining: 3)
        case .warning:
            // 2 impactos medios.
            pulse(medium, remaining: 2)
        }
    }

    private func pulse(_ generator: UIImpactFeedbackGenerator, remaining: Int) {
        guard remaining > 0 else { return }
        generator.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.pulse(generator, remaining: remaining - 1)
        }
    }
}
#endif
