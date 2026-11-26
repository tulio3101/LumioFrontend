#if os(iOS)
import Foundation
import OSLog

/// Implements SafetyMonitoring: drives the detection pipeline, converts detections to
/// SafetyEvents via onEvent and emits audio alerts through the AudioArbiter (never direct TTS).
/// El armado de los mensajes (contextID, captura, throttle) vive en ObstacleAnnouncer.
/// SCRUM-37: publica `status` (visible en Debug y Release), avisa una sola vez por episodio
/// cuando se pierde la asistencia (P1), confirma la recuperación (P2) y ofrece `retry()`.
/// Un fallo del detector nunca detiene la navegación ni recrea otros servicios.
@MainActor
final class SafetyService: ObservableObject, SafetyMonitoring {
    var onEvent: ((SafetyEvent) -> Void)?

    private let pipeline: any ObstacleDetectionPipeline
    private let audioArbiter: any AudioArbitrating
    /// SCRUM-314: vibra al quedar lista la detección. nil en pruebas que no la usan.
    private let haptics: (any HapticFeedbackPlaying)?
    private var announcer: ObstacleAnnouncer
    /// Configuración inyectada (intervalos y distancia de peligro) para reiniciar el estado.
    private let initialAnnouncer: ObstacleAnnouncer
    private var consumptionTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var isRunning = false
    /// Invalida un start() en curso si llega stop() o un reintento mientras prepara el modelo.
    private var sessionGeneration = 0
    @Published private(set) var status = SafetyStatus.stopped
    /// Un episodio de fallo genera un único aviso; los intentos de recuperación no lo repiten.
    private var outageAnnounced = false
    /// El modo (completo/reducido) se anuncia con la primera inferencia válida de la sesión.
    private var modeAnnounced = false

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
        announcer: ObstacleAnnouncer = ObstacleAnnouncer(),
        haptics: (any HapticFeedbackPlaying)? = nil
    ) {
        self.pipeline = pipeline
        self.audioArbiter = audioArbiter
        self.haptics = haptics
        self.announcer = announcer
        self.initialAnnouncer = announcer
    }

    func start() async throws {
        guard !isRunning else {
            logger.debug("start() — ya en ejecución, noop")
            return
        }
        isRunning = true
        sessionGeneration += 1
        let generation = sessionGeneration
        modeAnnounced = false
        logger.info("start() — preparando modelo y cámara")
        // SCRUM-37: el pipeline prepara el modelo antes de abrir la cámara y publica cada
        // cambio de estado. Nunca se anuncia «activo» solo por haber cargado el modelo.
        await pipeline.start()
        guard isRunning, generation == sessionGeneration, !Task.isCancelled else { return }
        statusTask = Task { [weak self, updates = pipeline.statusUpdates] in
            for await state in updates {
                guard !Task.isCancelled else { return }
                self?.handleStatus(state)
            }
        }
        consumptionTask = Task { [weak self, outputs = pipeline.detections] in
            for await output in outputs {
                guard !Task.isCancelled else { return }
                self?.handle(output)
            }
        }
    }

    func stop() {
        sessionGeneration += 1
        guard isRunning else {
            logger.debug("stop() — no en ejecución, noop")
            return
        }
        isRunning = false
        logger.info("stop()")
        announcer = initialAnnouncer
        #if DEBUG
        debugState.isActive = false
        debugState.fps = 0
        debugState.lastDetections = []
        #endif
        consumptionTask?.cancel()
        consumptionTask = nil
        statusTask?.cancel()
        statusTask = nil
        pipeline.stop()
        // Solo el contexto de seguridad: no pisar las instrucciones de navegación en curso.
        audioArbiter.cancel(contextIDs: [SafetyAudio.context])
        status = .stopped
        outageAnnounced = false
    }

    /// SCRUM-37: «Reintentar detección». Abre una sesión nueva con presupuesto de reintentos
    /// nuevo. Solo tiene efecto mientras la detección está pedida (hay una ruta activa), aunque
    /// haya quedado no disponible; no enciende la cámara por su cuenta fuera de una ruta.
    func retry() async {
        guard isRunning else { return }
        stop()
        try? await start()
    }

    private func handleStatus(_ next: SafetyStatus) {
        guard next != status else { return }
        status = next
        #if DEBUG
        debugState.isActive = next == .running
        debugState.isFullMode = pipeline.isDepthAvailable
        if next != .running {
            debugState.lastDetections = []
            debugState.fps = 0
        }
        #endif
        switch next {
        case .recovering, .unavailable:
            // Sin detección: se retiran los avisos de obstáculos pendientes (pueden ser viejos).
            announcer = initialAnnouncer
            audioArbiter.cancel(contextIDs: [SafetyAudio.context])
            if !outageAnnounced {
                outageAnnounced = true
                audioArbiter.receive(SafetyAudio.modelUnavailable())
            }
            if case .unavailable = next {
                logger.error("Detección no disponible: \(next.message)")
            }
        case .running:
            if outageAnnounced {
                outageAnnounced = false
                audioArbiter.cancel(contextIDs: [SafetyAudio.context])
                audioArbiter.receive(SafetyAudio.detectionRecovered())
            }
            if !modeAnnounced {
                modeAnnounced = true
                announceMode()
            }
        case .stopped, .starting:
            break
        }
    }

    // MARK: - SCRUM-320/349: mode announcement

    /// SCRUM-314: «cámara lista» por audio y vibración, nunca solo en pantalla. Solo con la
    /// primera inferencia válida: el modelo cargó, la cámara entrega frames y la seguridad ya
    /// funciona. Incluye el modo completo (LiDAR) o reducido (sin LiDAR).
    private func announceMode() {
        audioArbiter.receive(
            pipeline.isDepthAvailable ? SafetyAudio.fullMode() : SafetyAudio.reducedMode()
        )
        haptics?.play(.safetyReady)
    }

    // MARK: - Detection consumption

    private func handle(_ output: SafetyFrameOutput) {
        // SCRUM-37: solo se avisa con detección confirmada; durante la recuperación no hay avisos.
        guard status == .running else { return }
        let now = Date()
        #if DEBUG
        debugState.lastDetections = output.tracked.map(\.detection)
        debugState.lastDetectionDate = now
        debugFPSFrameCount += 1
        let elapsed = now.timeIntervalSince(debugFPSWindowStart)
        if elapsed >= 1.0 {
            debugState.fps = Double(debugFPSFrameCount) / elapsed
            debugFPSFrameCount = 0
            debugFPSWindowStart = now
        }
        #endif
        for out in announcer.announcements(for: output.tracked, now: now) {
            onEvent?(out.event)
            audioArbiter.receive(out.message)
        }
        // SCRUM-33: obstáculos por profundidad (ya filtrados/persistidos en el pipeline).
        for obstacle in output.depthObstacles {
            let out = announcer.depthObstacleOutput(
                kind: obstacle.kind, distanceMeters: obstacle.distanceMeters, now: now
            )
            onEvent?(out.event)
            audioArbiter.receive(out.message)
        }
    }
}
#endif
