#if os(iOS)
import CoreHaptics
import UIKit

/// Motor de vibración: reproduce los pulsos de un HapticPattern con UIImpactFeedbackGenerator.
/// Qué evento vibra y con qué intensidad lo decide HapticPreferencesService.
@MainActor
final class UIKitHapticFeedback: HapticPatternPlaying {
    private let generator = UIImpactFeedbackGenerator(style: .heavy)

    var supportsHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    func play(_ pattern: HapticPattern) {
        generator.prepare()
        for pulse in pattern.pulses {
            let intensity = CGFloat(min(max(pulse.strength, 0), 1))
            if pulse.delay <= 0 {
                generator.impactOccurred(intensity: intensity)
            } else {
                let nanoseconds = UInt64(pulse.delay * 1_000_000_000)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    self?.generator.impactOccurred(intensity: intensity)
                }
            }
        }
    }
}
#endif
