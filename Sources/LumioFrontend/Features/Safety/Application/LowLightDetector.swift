import Foundation

/// Detects insufficient ambient light using ARKit's lightEstimate.ambientIntensity.
/// SCRUM-249/250: configurable threshold. SCRUM-251: alerts via AudioArbiter + haptic engine (FeedbackCatalog).
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
    private let haptics: (any HapticFeedbackPlaying)?
    private var isAlertActive = false

    /// SCRUM-31: el aviso sale de `FeedbackCatalog` por el árbitro y el motor háptico (que
    /// aplica las preferencias del usuario); no hay un `UINotificationFeedbackGenerator` propio.
    init(
        audioArbiter: any AudioArbitrating,
        haptics: (any HapticFeedbackPlaying)? = nil,
        alertThreshold: Float = 100.0,
        hysteresisMargin: Float = 40.0
    ) {
        self.audioArbiter = audioArbiter
        self.haptics = haptics
        self.alertThreshold = alertThreshold
        self.hysteresisMargin = hysteresisMargin
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
            FeedbackCatalog.emit(.lowLight, audio: self.audioArbiter, haptics: self.haptics)
        }
    }

    private func emitRecovery() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // SCRUM-36: deja de alertar y lo confirma por audio (P3) al volver la luz adecuada.
            FeedbackCatalog.emit(.lowLightRecovered, audio: self.audioArbiter, haptics: self.haptics)
        }
    }
}
