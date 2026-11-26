#if os(iOS)
import CoreVideo
import Foundation
import OSLog

/// Connects a FrameSource to a YOLORunner and enriches detections with depth when available.
/// Runs detection in a background task; "latest frame wins" is inherited from FrameSource.
/// SCRUM-218: exposes [Detection] stream. SCRUM-220: associates depth. SCRUM-223: loop + restart.
/// SCRUM-37: Core ML vive en `RecoveringModel` (carga e inferencia con reintentos 1/2/4 s) y el
/// estado de la detección se publica en `statusUpdates`. Cada `start()` crea flujos nuevos.
final class DetectionPipeline: ObstacleDetectionPipeline {
    let frameSource: FrameSource
    private let runnerFactory: () throws -> any ObstacleDetecting
    /// SCRUM-314: con un modelo compartido, lo olvida antes de reconstruirlo tras un fallo.
    private let discardRunner: () -> Void
    private let recoveryPolicy: ModelRecoveryPolicy
    private let confidencePolicy: ClassConfidencePolicy
    private let lowLightDetector: LowLightDetector?
    private let focusConfig: DetectionFocusConfig
    private let pitchReminder: PhonePitchReminder?

    var isDepthAvailable: Bool { frameSource.isDepthAvailable }
    #if DEBUG
    var previewFrameSource: ARKitFrameSource? { frameSource as? ARKitFrameSource }
    #endif

    private(set) var detections: AsyncStream<SafetyFrameOutput>
    private var detectionsContinuation: AsyncStream<SafetyFrameOutput>.Continuation
    private(set) var statusUpdates: AsyncStream<SafetyStatus>
    private var statusContinuation: AsyncStream<SafetyStatus>.Continuation
    private var processingTask: Task<Void, Never>?
    /// Invalida sesiones viejas: un start() o stop() posterior gana a uno anterior en curso.
    private var generation = 0

    private let logger = Logger(subsystem: "com.lumio.app", category: "DetectionPipeline")
    // Throttle var: data race on this static is intentional for debug logs.
    #if DEBUG
    private static var lastFrameLogTime: Double = 0
    #endif

    init(
        frameSource: FrameSource,
        runnerFactory: @escaping () throws -> any ObstacleDetecting = { try YOLORunner() },
        discardRunner: @escaping () -> Void = {},
        recoveryPolicy: ModelRecoveryPolicy = ModelRecoveryPolicy(),
        confidencePolicy: ClassConfidencePolicy = .default,
        lowLightDetector: LowLightDetector? = nil,
        focusConfig: DetectionFocusConfig = DetectionFocusConfig(),
        pitchReminder: PhonePitchReminder? = nil
    ) {
        self.frameSource = frameSource
        self.runnerFactory = runnerFactory
        self.discardRunner = discardRunner
        self.recoveryPolicy = recoveryPolicy
        self.confidencePolicy = confidencePolicy
        self.lowLightDetector = lowLightDetector
        self.focusConfig = focusConfig
        self.pitchReminder = pitchReminder
        let output = makeSafetyStream(of: SafetyFrameOutput.self, bufferingPolicy: .bufferingNewest(1))
        detections = output.stream
        detectionsContinuation = output.continuation
        let state = makeSafetyStream(of: SafetyStatus.self)
        statusUpdates = state.stream
        statusContinuation = state.continuation
    }

    /// SCRUM-37: prepara el modelo ANTES de abrir la cámara. Un modelo ausente o que no carga
    /// tras los reintentos publica `.unavailable` sin encender la captura. Llamar de nuevo
    /// (reintento manual o nueva ruta) cierra la sesión anterior y abre flujos nuevos.
    func start() async {
        generation += 1
        let session = generation
        processingTask?.cancel()
        frameSource.stop()
        // Una inferencia síncrona ya iniciada termina antes de abrir otra sesión.
        await processingTask?.value
        guard session == generation, !Task.isCancelled else { return }
        let output = makeSafetyStream(of: SafetyFrameOutput.self, bufferingPolicy: .bufferingNewest(1))
        detections = output.stream
        detectionsContinuation = output.continuation
        let state = makeSafetyStream(of: SafetyStatus.self)
        statusUpdates = state.stream
        statusContinuation = state.continuation
        let factory = runnerFactory
        let discard = discardRunner
        let policy = recoveryPolicy
        let source = frameSource
        processingTask = Task.detached(priority: .userInitiated) { [weak self] in
            let model = RecoveringModel<CVPixelBuffer, [Detection]>(factory: {
                let runner = try factory()
                return { try runner.detect(pixelBuffer: $0) }
            }, policy: policy, report: { state.continuation.yield($0) }, discard: discard)
            defer {
                output.continuation.finish()
                state.continuation.finish()
            }
            guard await model.prepare(), !Task.isCancelled, let self else { return }
            let frames: AsyncStream<CapturedFrame>
            do {
                frames = try await MainActor.run {
                    // Un stop() pudo llegar mientras se preparaba el modelo: no abrir la cámara.
                    try Task.checkCancellation()
                    try source.start()
                    return source.frames
                }
            } catch is CancellationError {
                return
            } catch {
                Logger(subsystem: "com.lumio.app", category: "DetectionPipeline")
                    .error("No se pudo iniciar la captura: \(error)")
                state.continuation.yield(.unavailable(.camera))
                await MainActor.run { source.stop() }
                return
            }
            await self.process(frames, using: model, output: output.continuation)
            guard !Task.isCancelled else { return }
            if case .unavailable = await model.status {
                // El fallo del modelo ya se publicó.
            } else {
                // La cámara terminó el flujo sin que nadie llamara a stop() (fallo de ARKit).
                state.continuation.yield(.unavailable(.camera))
            }
            await MainActor.run { source.stop() }
        }
    }

    func stop() {
        generation += 1
        // Se conserva la referencia: el próximo start() espera a que esta tarea termine.
        processingTask?.cancel()
        frameSource.stop()
        detectionsContinuation.finish()
        statusContinuation.finish()
    }

    /// SCRUM-223: restart after an interruption. SCRUM-37: es una sesión nueva completa.
    func restart() async { await start() }

    /// Ciclo por frame (SCRUM-33): poca luz, inclinación, confianza por clase, suavizado,
    /// profundidad, rastreo y obstáculos por profundidad. Termina si el modelo queda no disponible.
    private func process(
        _ frames: AsyncStream<CapturedFrame>,
        using model: RecoveringModel<CVPixelBuffer, [Detection]>,
        output: AsyncStream<SafetyFrameOutput>.Continuation
    ) async {
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
        // SCRUM-33 (desniveles): persistencia más estricta (5 de 7) + cooldown por tipo de peligro.
        let elevationAnalyzer = ElevationProfileAnalyzer()
        var elevationGate = PersistenceGate(
            minAppearances: self.focusConfig.elevationMinAppearances,
            windowFrames: self.focusConfig.elevationWindowFrames,
            cooldown: self.focusConfig.depthCooldownSeconds
        )
        // SCRUM-321: política térmica. Limita los fps de inferencia según el estado térmico y el
        // Modo de Bajo Consumo, y pausa la detección en calor crítico. `wasPaused` emite una sola
        // transición por episodio. `lastProcessedTimestamp` implementa el límite de fps.
        let thermalPolicy = ThermalPolicy()
        var wasPaused = false
        var lastProcessedTimestamp: Double = 0
        var telemetry = DetectionTelemetry()
        for await frame in frames {
            // Always release the gate when done — even if Task is cancelled or detect() throws.
            defer { self.frameSource.frameProcessingComplete() }
            guard !Task.isCancelled else { return }

            // SCRUM-321: carga térmica de este frame (lecturas thread-safe de ProcessInfo).
            let load = thermalPolicy.load(
                for: Self.thermalLevel(),
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
            if load.isPaused {
                // Calor crítico: se pausa la inferencia. Se avisa una sola vez (transición).
                if !wasPaused {
                    wasPaused = true
                    output.yield(SafetyFrameOutput(thermalPaused: true))
                }
                telemetry.recordDropped()
                continue
            }
            if wasPaused {
                wasPaused = false
                output.yield(SafetyFrameOutput(thermalPaused: false))   // reanudada al enfriar
            }
            // Límite de fps: descarta el frame si llegó antes del intervalo objetivo.
            let minInterval = 1.0 / Double(load.targetFPS)
            if frame.timestamp - lastProcessedTimestamp < minInterval {
                telemetry.recordDropped()
                continue
            }
            lastProcessedTimestamp = frame.timestamp

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
                output.yield(SafetyFrameOutput())
                continue
            }

            // SCRUM-37: un fallo NO se convierte en lista vacía. El frame fallido se descarta
            // (el siguiente usa un frame nuevo) y, agotados los reintentos, termina el ciclo.
            let inferenceStart = DispatchTime.now()
            guard let raw = await model.process(frame.pixelBuffer) else {
                if case .unavailable = await model.status { return }
                continue
            }
            guard !Task.isCancelled else { return }
            // SCRUM-321: telemetría (solo Debug): fps procesados, latencia de inferencia, frames
            // descartados, estado térmico. Resumen cada 30 s.
            let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - inferenceStart.uptimeNanoseconds) / 1_000_000
            telemetry.recordProcessed(latencyMs: latencyMs)
            telemetry.logSummaryIfDue(targetFPS: load.targetFPS, logger: self.logger)
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

            // SCRUM-33: desniveles (escalón/escalera/bordillo/rampa). Solo con LiDAR y con el piso
            // bajo los pies. Persistencia + cooldown por tipo.
            var elevationHazards: [ElevationHazardSignal] = []
            var elevationProfile: ElevationProfile?
            var rawHazard: ElevationHazard?
            if self.frameSource.isDepthAvailable, let depth = frame.depthData,
               let camera = frame.camera, let floorHeight = frame.floorHeight {
                let rect = corridor.rect(pitchDegrees: pitchDegrees ?? 0)
                elevationProfile = ElevationProfileSampler.profile(
                    from: depth, corridor: rect, camera: camera, floorHeight: floorHeight,
                    nearMeters: self.focusConfig.elevationNearMeters,
                    farMeters: self.focusConfig.elevationFarMeters,
                    ceilingMeters: self.focusConfig.elevationCeilingMeters
                )
                // El piso viene del plano bajo los pies: una bajada que arranca en el borde (sin
                // muestras de piso visibles antes) igual se detecta.
                rawHazard = elevationProfile.map {
                    elevationAnalyzer.analyze($0, config: self.focusConfig, hasKnownFloor: true)
                }
                let announcement = rawHazard.flatMap { ElevationAudio.announcement(for: $0) }
                let present: Set<String> = announcement.map { [$0.typeKey] } ?? []
                let fire = elevationGate.update(present: present, now: Date())
                if let hazard = rawHazard, let announcement, fire.contains(announcement.typeKey) {
                    elevationHazards.append(
                        ElevationHazardSignal(hazard: hazard, isDanger: announcement.isDanger)
                    )
                }
            }

            var frameOutput = SafetyFrameOutput(
                tracked: tracked, depthObstacles: depthObstacles, elevationHazards: elevationHazards
            )
            #if DEBUG
            frameOutput.debug = SafetyDebugFrame(
                timestamp: frame.timestamp,
                pitchDegrees: pitchDegrees,
                floorHeight: frame.floorHeight,
                cameraHeightAboveFloor: frame.camera.flatMap { cam in
                    frame.floorHeight.map { cam.transform.columns.3.y - $0 }
                },
                profileForward: elevationProfile?.samples.map(\.forwardMeters) ?? [],
                profileHeights: elevationProfile?.samples.map(\.heightAboveFloor) ?? [],
                rawHazard: rawHazard?.debugLabel ?? (frame.floorHeight == nil ? "sin piso" : "plano"),
                announcedHazards: elevationHazards.map { $0.hazard.debugLabel },
                rawDetections: raw.map {
                    SafetyDebugFrame.RawDetection(cls: $0.obstacleClass.rawValue, confidence: $0.confidence)
                },
                trackedCount: tracked.count,
                depthObstacleCount: depthObstacles.count
            )
            #endif
            output.yield(frameOutput)
            // frame goes out of scope here — CVPixelBuffer/ARDepthData are released.
        }
    }

    /// SCRUM-321: estado térmico actual (lectura thread-safe) como nivel abstracto para la política.
    static func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }

    static func thermalStateName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }
}

/// SCRUM-321: contadores de rendimiento del pipeline. Resumen cada 30 s (solo Debug).
private struct DetectionTelemetry {
    private var processed = 0
    private var dropped = 0
    private var latencySumMs: Double = 0
    private var windowStart = DispatchTime.now()
    private let summaryInterval: Double = 30

    mutating func recordProcessed(latencyMs: Double) {
        processed += 1
        latencySumMs += latencyMs
    }

    mutating func recordDropped() { dropped += 1 }

    mutating func logSummaryIfDue(targetFPS: Int, logger: Logger) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - windowStart.uptimeNanoseconds) / 1_000_000_000
        guard elapsed >= summaryInterval else { return }
        #if DEBUG
        let fps = Double(processed) / elapsed
        let avgLatency = processed > 0 ? latencySumMs / Double(processed) : 0
        logger.debug("""
            SCRUM-321 telemetría \(Int(elapsed), privacy: .public)s: \
            fps=\(fps, format: .fixed(precision: 1), privacy: .public)/\(targetFPS, privacy: .public) \
            latencia=\(avgLatency, format: .fixed(precision: 1), privacy: .public)ms \
            descartados=\(dropped, privacy: .public) \
            térmico=\(DetectionPipeline.thermalStateName(), privacy: .public)
            """)
        #endif
        processed = 0
        dropped = 0
        latencySumMs = 0
        windowStart = DispatchTime.now()
    }
}
#endif
