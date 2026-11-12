#if os(iOS)
import Foundation
import OSLog

/// Implements SafetyMonitoring: drives the detection pipeline, converts detections to
/// SafetyEvents via onEvent and emits audio alerts through the AudioArbiter (never direct TTS).
/// El armado de los mensajes (contextID, captura, throttle) vive en ObstacleAnnouncer.
@MainActor
final class SafetyService: ObservableObject, SafetyMonitoring {
    var onEvent: ((SafetyEvent) -> Void)?

    private let pipeline: any ObstacleDetectionPipeline
    private let audioArbiter: any AudioArbitrating
    private var announcer: ObstacleAnnouncer
    private var consumptionTask: Task<Void, Never>?
    private var isRunning = false

    private let logger = Logger(subsystem: "com.lumio.app", category: "SafetyService")

    // MARK: - Debug state (Debug builds only)

    #if DEBUG
    struct DebugState {
        var isActive = false
        var isFullMode = false
        var lastDetections: [Detection] = []
        var lastDetectionDate: Date?
        var fps: Double = 0
    }
    @Published var debugState = DebugState()
    private var debugFPSFrameCount = 0
    private var debugFPSWindowStart = Date()

    var debugPreviewFrameSource: ARKitFrameSource? { pipeline.previewFrameSource }
    #endif

    init(
        pipeline: any ObstacleDetectionPipeline,
        audioArbiter: any AudioArbitrating,
        announcer: ObstacleAnnouncer = ObstacleAnnouncer()
    ) {
        self.pipeline = pipeline
        self.audioArbiter = audioArbiter
        self.announcer = announcer
    }

    func start() async throws {
        guard !isRunning else {
            logger.debug("start() — ya en ejecución, noop")
            return
        }
        isRunning = true
        logger.info("start() — isDepthAvailable=\(self.pipeline.isDepthAvailable)")
        do {
            try pipeline.start()
        } catch {
            isRunning = false
            logger.error("pipeline.start() falló: \(error)")
            throw error
        }
        logger.info("pipeline arrancado OK")
        announceMode()
        #if DEBUG
        debugState.isActive = true
        debugState.isFullMode = pipeline.isDepthAvailable
        #endif
        consumptionTask = Task { [weak self] in
            await self?.consumeLoop()
        }
    }

    func stop() {
        guard isRunning else {
            logger.debug("stop() — no en ejecución, noop")
            return
        }
        isRunning = false
        logger.info("stop()")
        announcer = ObstacleAnnouncer()
        #if DEBUG
        debugState.isActive = false
        debugState.fps = 0
        debugState.lastDetections = []
        #endif
        consumptionTask?.cancel()
        consumptionTask = nil
        pipeline.stop()
        // Solo el contexto de seguridad: no pisar las instrucciones de navegación en curso.
        audioArbiter.cancel(contextIDs: [SafetyAudio.context])
    }

    // MARK: - SCRUM-349: mode announcement

    private func announceMode() {
        guard !pipeline.isDepthAvailable else { return }
        audioArbiter.receive(SafetyAudio.reducedMode())
    }

    // MARK: - Detection consumption loop

    private func consumeLoop() async {
        for await detections in pipeline.detections {
            guard !Task.isCancelled else { return }
            handle(detections)
        }
    }

    private func handle(_ detections: [Detection]) {
        #if DEBUG
        debugState.lastDetections = detections
        debugState.lastDetectionDate = Date()
        debugFPSFrameCount += 1
        let elapsed = Date().timeIntervalSince(debugFPSWindowStart)
        if elapsed >= 1.0 {
            debugState.fps = Double(debugFPSFrameCount) / elapsed
            debugFPSFrameCount = 0
            debugFPSWindowStart = Date()
        }
        #endif
        for output in announcer.announcements(for: detections, now: Date()) {
            onEvent?(output.event)
            audioArbiter.receive(output.message)
        }
    }
}
#endif
