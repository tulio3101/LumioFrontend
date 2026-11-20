#if os(iOS)
import CoreVideo
import OSLog

/// Connects a FrameSource to a YOLORunner and enriches detections with depth when available.
/// Runs detection in a background task; "latest frame wins" is inherited from FrameSource.
/// SCRUM-218: exposes [Detection] stream. SCRUM-220: associates depth. SCRUM-223: loop + restart.
final class DetectionPipeline: ObstacleDetectionPipeline {
    let frameSource: FrameSource
    private let runner: YOLORunner
    private let confidencePolicy: ClassConfidencePolicy
    private let lowLightDetector: LowLightDetector?
    private let focusConfig: DetectionFocusConfig
    private let pitchReminder: PhonePitchReminder?

    var isDepthAvailable: Bool { frameSource.isDepthAvailable }
    #if DEBUG
    var previewFrameSource: ARKitFrameSource? { frameSource as? ARKitFrameSource }
    #endif

    private(set) var detections: AsyncStream<SafetyFrameOutput>
    private let detectionsContinuation: AsyncStream<SafetyFrameOutput>.Continuation
    private var processingTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.lumio.app", category: "DetectionPipeline")
    // Throttle var: data race on this static is intentional for debug logs.
    #if DEBUG
    private static var lastFrameLogTime: Double = 0
    #endif

    init(
        frameSource: FrameSource,
        runner: YOLORunner,
        confidencePolicy: ClassConfidencePolicy = .default,
        lowLightDetector: LowLightDetector? = nil,
        focusConfig: DetectionFocusConfig = DetectionFocusConfig(),
        pitchReminder: PhonePitchReminder? = nil
    ) {
        self.frameSource = frameSource
        self.runner = runner
        self.confidencePolicy = confidencePolicy
        self.lowLightDetector = lowLightDetector
        self.focusConfig = focusConfig
        self.pitchReminder = pitchReminder
        var cont: AsyncStream<SafetyFrameOutput>.Continuation!
        detections = AsyncStream<SafetyFrameOutput>(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
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
            // One smoother + tracker + depth gate per processing Task; reset on restart (new Task).
            var smoother = TemporalSmoother()
            var tracker = ObstacleTracker(config: self.focusConfig)
            let corridor = WalkingCorridor(config: self.focusConfig)
            let halfWidth = Float(self.focusConfig.corridorWidthFraction / 2)
            let depthDetector = DepthObstacleDetector(
                maxAlertDistance: ObstacleAnnouncer.farThresholdMeters,
                corridorXRange: (0.5 - halfWidth)...(0.5 + halfWidth)
            )
            var depthGate = PersistenceGate(
                minAppearances: self.focusConfig.depthMinAppearances,
                windowFrames: self.focusConfig.depthWindowFrames,
                cooldown: self.focusConfig.depthCooldownSeconds
            )
            for await frame in self.frameSource.frames {
                // Always release the gate when done — even if Task is cancelled or detect() throws.
                defer { self.frameSource.frameProcessingComplete() }
                guard !Task.isCancelled else { return }

                // Low-light check: plain Float from ARKit, no frame retention.
                if let intensity = frame.ambientIntensity {
                    self.lowLightDetector?.analyze(ambientIntensity: intensity)
                }

                // Inclinación del teléfono (ARKit está alineado a gravedad): si apunta al piso
                // o al cielo, avisa una vez y no detecta ruido ese frame.
                // eulerAngles.x es el pitch en radianes; el eje/signo puede calibrarse en campo.
                let pitchDegrees: Float? = frame.camera.map { $0.eulerAngles.x * 180 / .pi }
                let tilt = pitchState(
                    pitchDegrees ?? 0,
                    minDegrees: self.focusConfig.minPitchDegrees,
                    maxDegrees: self.focusConfig.maxPitchDegrees
                )
                if self.pitchReminder?.analyze(tilt, now: Date()) == true {
                    self.detectionsContinuation.yield(SafetyFrameOutput())
                    continue
                }

                let raw = (try? self.runner.detect(pixelBuffer: frame.pixelBuffer)) ?? []
                // Drop detections below the per-class confidence threshold, then require
                // temporal persistence before passing anything downstream.
                let confident = raw.filter { $0.confidence >= self.confidencePolicy.threshold(for: $0.obstacleClass) }
                let stable = smoother.filter(confident)

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
                    enriched = stable.map { det in
                        var d = det
                        d.distanceMeters = DepthSampler.sampleDepth(
                            at: det.boundingBox,
                            depthData: depth
                        )
                        return d
                    }
                } else {
                    enriched = stable
                }
                // SCRUM-33: corredor de marcha + rastreo por objeto (IDs estables, persistencia,
                // acercamiento). Las alertas pasan a ser por objeto, no por frame.
                let tracked = tracker.update(enriched, pitchDegrees: pitchDegrees)

                // SCRUM-33: obstáculo por profundidad (independiente de la clase). Solo con LiDAR y
                // con el piso estimado (para descontarlo). Fusiona con YOLO (gana el nombre YOLO),
                // y pasa por persistencia N-de-M + cooldown (igual que las cajas).
                var depthObstacles: [DepthObstacleSignal] = []
                if self.frameSource.isDepthAvailable, let depth = frame.depthData,
                   let camera = frame.camera, let floorHeight = frame.floorHeight {
                    let rect = corridor.rect(pitchDegrees: pitchDegrees ?? 0)
                    let hit = CorridorDepthSampler.grid(
                        from: depth, corridor: rect, camera: camera,
                        floorHeight: floorHeight, floorBand: self.focusConfig.floorBandMeters
                    ).flatMap { depthDetector.detect($0) }
                    let kind = DepthObstacleKind(meshClass: frame.meshClassification?.dominantClass ?? .none)
                    let surviving = DepthObstacleFusion.survivingObstacle(
                        hit, kind: kind, yoloBoxes: tracked.map(\.boundingBox)
                    )
                    let present: Set<String> = surviving.map { [$0.kind.rawValue] } ?? []
                    let announce = depthGate.update(present: present, now: Date())
                    if let surviving, announce.contains(surviving.kind.rawValue) {
                        depthObstacles.append(
                            DepthObstacleSignal(kind: surviving.kind, distanceMeters: surviving.hit.distance)
                        )
                    }
                }

                self.detectionsContinuation.yield(
                    SafetyFrameOutput(tracked: tracked, depthObstacles: depthObstacles)
                )
                // frame goes out of scope here — CVPixelBuffer/ARDepthData are released.
            }
        }
    }
}
#endif
