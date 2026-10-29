#if canImport(UIKit)
import UIKit

/// Anuncia a VoiceOver un resultado o error sin mover el foco.
@MainActor
func announceForAccessibility(_ message: String) {
    UIAccessibility.post(notification: .announcement, argument: message)
}
#else
@MainActor
func announceForAccessibility(_ message: String) {}
#endif
