#if os(iOS)
import Foundation

/// Implements SafetyMonitoring: drives the DetectionPipeline, converts detections to
/// SafetyEvents via onEvent, emits audio alerts through AudioArbiter (never direct TTS).
/// SCRUM-349: announces operating mode at startup.
@MainActor
final class SafetyService: SafetyMonitoring {
    var onEvent: ((SafetyEvent) -> Void)?

    private let pipeline: DetectionPipeline
    private let audioArbiter: AudioArbiterService
    private var consumptionTask: Task<Void, Never>?

    init(pipeline: DetectionPipeline, audioArbiter: AudioArbiterService) {
        self.pipeline = pipeline
        self.audioArbiter = audioArbiter
    }

    func start() async throws {
        try pipeline.start()
        announceMode()
        consumptionTask = Task { [weak self] in
            await self?.consumeLoop()
        }
    }

    func stop() {
        consumptionTask?.cancel()
        consumptionTask = nil
        pipeline.stop()
        audioArbiter.resetSession()
    }

    // MARK: - SCRUM-349: mode announcement

    private func announceMode() {
        guard !pipeline.frameSource.isDepthAvailable else { return }
        // Reduced mode: LiDAR not available. Warn the user per ADR-307.
        audioArbiter.receive(AudioMessage(
            text: "Modo reducido. Los avisos de distancia son aproximados y de corto alcance.",
            priority: .environmentInformation,
            deduplicationKey: "safety-mode-reduced"
        ))
    }

    // MARK: - Detection consumption loop

    private func consumeLoop() async {
        for await detections in pipeline.detections {
            guard !Task.isCancelled else { return }
            handle(detections)
        }
    }

    private func handle(_ detections: [Detection]) {
        for det in detections {
            let requiresImmediate = isHighRisk(det)
            let event = SafetyEvent(
                id: UUID(),
                description: audioText(for: det),
                detectedAt: Date(),
                requiresImmediateAction: requiresImmediate
            )
            onEvent?(event)
            audioArbiter.receive(AudioMessage(
                text: event.description,
                priority: requiresImmediate ? .immediateRisk : .environmentInformation,
                expiresAt: Date().addingTimeInterval(2),
                deduplicationKey: "obstacle-\(det.obstacleClass.rawValue)"
            ))
        }
    }

    private func isHighRisk(_ det: Detection) -> Bool {
        guard let dist = det.distanceMeters else {
            // No depth info: treat as high risk only for fast-moving obstacles.
            return det.obstacleClass == .car || det.obstacleClass == .motorcycle
                || det.obstacleClass == .bus || det.obstacleClass == .truck
        }
        return dist <= 1.5
    }

    private func audioText(for det: Detection) -> String {
        var text = det.obstacleClass.rawValue
        if let dist = det.distanceMeters {
            if dist <= 3.0 {
                text += " a \(String(format: "%.1f", dist)) metros"
            } else {
                text += " cerca"
            }
        }
        return text
    }
}
#endif
