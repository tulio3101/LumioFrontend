#if os(iOS)
import CoreVideo
import OSLog

/// Connects a FrameSource to a YOLORunner and enriches detections with depth when available.
/// Runs detection in a background task; "latest frame wins" is inherited from FrameSource.
/// SCRUM-218: exposes [Detection] stream. SCRUM-220: associates depth. SCRUM-223: loop + restart.
final class DetectionPipeline {
    let frameSource: FrameSource
    private let runner: YOLORunner

    private(set) var detections: AsyncStream<[Detection]>
    private let detectionsContinuation: AsyncStream<[Detection]>.Continuation
    private var processingTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.lumio.app", category: "DetectionPipeline")
    // Throttle var: data race on this static is intentional for debug logs.
    #if DEBUG
    private static var lastFrameLogTime: Double = 0
    #endif

    init(frameSource: FrameSource, runner: YOLORunner) {
        self.frameSource = frameSource
        self.runner = runner
        var cont: AsyncStream<[Detection]>.Continuation!
        detections = AsyncStream<[Detection]>(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        detectionsContinuation = cont
    }

    func start() throws {
        try frameSource.start()
        spawnProcessingLoop()
    }

    func stop() {
        processingTask?.cancel()
        processingTask = nil
        frameSource.stop()
        detectionsContinuation.finish()
    }

    /// SCRUM-223: restart after an interruption (e.g. phone call ends, VoiceOver resumes).
    func restart() throws {
        processingTask?.cancel()
        try frameSource.start()
        spawnProcessingLoop()
    }

    private func spawnProcessingLoop() {
        processingTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for await frame in self.frameSource.frames {
                // Always release the gate when done — even if Task is cancelled or detect() throws.
                defer { self.frameSource.frameProcessingComplete() }
                guard !Task.isCancelled else { return }

                let raw = (try? self.runner.detect(pixelBuffer: frame.pixelBuffer)) ?? []

                #if DEBUG
                let ts = frame.timestamp
                if ts - DetectionPipeline.lastFrameLogTime > 1.0 {
                    DetectionPipeline.lastFrameLogTime = ts
                    self.logger.debug("frame en pipeline ts=\(ts, format: .fixed(precision: 1))")
                    if !raw.isEmpty {
                        self.logger.debug("detecciones: \(raw.count) — \(raw.map { $0.obstacleClass.rawValue }.joined(separator: ", "))")
                    }
                }
                #endif

                // SCRUM-220: enrich each detection with LiDAR depth when available.
                let enriched: [Detection]
                if self.frameSource.isDepthAvailable, let depth = frame.depthData {
                    enriched = raw.map { det in
                        var d = det
                        d.distanceMeters = DepthSampler.sampleDepth(
                            at: det.boundingBox,
                            depthData: depth
                        )
                        return d
                    }
                } else {
                    enriched = raw
                }
                self.detectionsContinuation.yield(enriched)
                // frame goes out of scope here — CVPixelBuffer/ARDepthData are released.
            }
        }
    }
}
#endif
