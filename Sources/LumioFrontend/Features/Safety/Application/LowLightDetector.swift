#if os(iOS)
import CoreVideo
import UIKit

/// Detects insufficient ambient light by analyzing the Y (luminance) plane of camera frames.
/// SCRUM-249/250: configurable threshold. SCRUM-251: alerts via AudioArbiter + haptics.
/// SCRUM-252: hysteresis prevents alert/recover flicker at the threshold boundary.
/// SCRUM-253: fully on-device, no network dependency.
final class LowLightDetector {
    /// Normalized luminance [0…1] below which low-light is declared.
    let alertThreshold: Float
    /// Luminance must exceed alertThreshold + hysteresisMargin to recover.
    let hysteresisMargin: Float

    private let audioArbiter: AudioArbiterService
    private var isAlertActive = false
    private let feedbackGenerator = UINotificationFeedbackGenerator()

    init(
        audioArbiter: AudioArbiterService,
        alertThreshold: Float = 0.15,
        hysteresisMargin: Float = 0.05
    ) {
        self.audioArbiter = audioArbiter
        self.alertThreshold = alertThreshold
        self.hysteresisMargin = hysteresisMargin
        feedbackGenerator.prepare()
    }

    /// Call with each camera frame from the detection pipeline.
    func analyze(pixelBuffer: CVPixelBuffer) {
        let luminance = averageLuminance(pixelBuffer)
        if !isAlertActive, luminance < alertThreshold {
            isAlertActive = true
            emitAlert()
        } else if isAlertActive, luminance >= alertThreshold + hysteresisMargin {
            isAlertActive = false
            emitRecovery()
        }
    }

    // MARK: - Private

    private func averageLuminance(_ buffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        // ARKit frames: 420YpCbCr8BiPlanarFullRange — plane 0 is Y (luminance), 8 bpp.
        guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { return 1.0 }
        let base   = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
                         .assumingMemoryBound(to: UInt8.self)
        let width  = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)

        // Sample every 8th pixel to keep CPU cost negligible.
        var sum: UInt64 = 0
        var count: UInt64 = 0
        var y = 0
        while y < height {
            let row = base.advanced(by: y * stride)
            var x = 0
            while x < width {
                sum += UInt64(row[x])
                count += 1
                x += 8
            }
            y += 8
        }
        guard count > 0 else { return 1.0 }
        return Float(sum) / Float(count) / 255.0
    }

    private func emitAlert() {
        // analyze() is called from any thread; audio and haptics must run on main actor.
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
