#if canImport(UIKit)
import UIKit

/// Anuncia a VoiceOver un resultado o error sin mover el foco.
@MainActor
func announceForAccessibility(_ message: String) {
    UIAccessibility.post(notification: .announcement, argument: message)
}

/// Como `announceForAccessibility`, pero espera a que VoiceOver termine lo que está diciendo
/// (por ejemplo, el eco del teclado) en lugar de interrumpirlo.
@MainActor
func announceForAccessibilityQueued(_ message: String) {
    let text = NSAttributedString(string: message, attributes: [.accessibilitySpeechQueueAnnouncement: true])
    UIAccessibility.post(notification: .announcement, argument: text)
}
#else
@MainActor
func announceForAccessibility(_ message: String) {}

@MainActor
func announceForAccessibilityQueued(_ message: String) {}
#endif
