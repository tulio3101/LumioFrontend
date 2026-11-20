#if os(iOS)
import UIKit

/// Detects insufficient ambient light using ARKit's lightEstimate.ambientIntensity.
/// SCRUM-249/250: configurable threshold. SCRUM-251: alerts via AudioArbiter + haptics.
/// SCRUM-252: hysteresis prevents alert/recover flicker at the threshold boundary.
/// SCRUM-253: fully on-device, no network dependency.
///
/// API note: analyze(ambientIntensity:) accepts a plain Float read inside session(_:didUpdate:)
/// — no CVPixelBuffer, no ARFrame retention. Previous API (analyze(pixelBuffer:)) was removed
/// because sampling the Y plane retained the IOSurface and contributed to
/// "ARSession is retaining N ARFrames." ARKit's own lightEstimate is also more accurate.
final class LowLightDetector {
    /// ARKit ambient intensity (lux) below which low-light is declared.
    /// Typical indoor range: 200–500. Dark room: < 100. Bright daylight: > 1000.
    let alertThreshold: Float
    /// Intensity must exceed alertThreshold + hysteresisMargin to recover.
    let hysteresisMargin: Float

    private let audioArbiter: any AudioArbitrating
    private var isAlertActive = false
    private let feedbackGenerator = UINotificationFeedbackGenerator()

    init(
        audioArbiter: any AudioArbitrating,
        alertThreshold: Float = 100.0,
        hysteresisMargin: Float = 40.0
    ) {
        self.audioArbiter = audioArbiter
        self.alertThreshold = alertThreshold
        self.hysteresisMargin = hysteresisMargin
        feedbackGenerator.prepare()
    }

    /// Call with ARFrame.lightEstimate.ambientIntensity (read as a Float inside the delegate,
    /// before any gate check). Safe to call from any thread.
    func analyze(ambientIntensity: Float) {
        if !isAlertActive, ambientIntensity < alertThreshold {
            isAlertActive = true
            emitAlert()
        } else if isAlertActive, ambientIntensity >= alertThreshold + hysteresisMargin {
            isAlertActive = false
            emitRecovery()
        }
    }

    // MARK: - Private

    private func emitAlert() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioArbiter.receive(AudioMessage(
                text: "Poca luz. Avanza con precaución.",
                priority: .immediateRisk,
                deduplicationKey: "low-light-alert"
            ))
            self.feedbackGenerator.notificationOccurred(.warning)
        }
    }

    private func emitRecovery() {
        Task { @MainActor [weak self] in
            self?.feedbackGenerator.notificationOccurred(.success)
        }
    }
}
#endif
