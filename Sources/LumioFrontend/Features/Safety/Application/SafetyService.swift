#if os(iOS)
import Foundation
import OSLog

/// Implements SafetyMonitoring: drives the DetectionPipeline, converts detections to
/// SafetyEvents via onEvent, emits audio alerts through AudioArbiter (never direct TTS).
/// SCRUM-349: announces operating mode at startup.
@MainActor
final class SafetyService: ObservableObject, SafetyMonitoring {
    var onEvent: ((SafetyEvent) -> Void)?

    private let pipeline: DetectionPipeline
    private let audioArbiter: AudioArbiterService
    private var consumptionTask: Task<Void, Never>?
    private var isRunning = false

    private let logger = Logger(subsystem: "com.lumio.app", category: "SafetyService")

    // MARK: - Announcement throttle

    // NOTE (desvío de ADR-307): ADR-307 usaba centímetros para < 1 m y silenciaba > 4 m.
    // Decisión posterior: siempre en metros con un decimal y coma ("0,3 metros", "1,5 metros"),
    // y para > 4 m anunciar "a más de 4 metros" con prioridad .environmentInformation.
    private enum DistanceTier: Equatable {
        case immediate   // < 1 m — interrupts with .immediateRisk
        case normal      // 1–4 m — .environmentInformation
        case far         // > 4 m — "a más de 4 metros", .environmentInformation
        case noDistance  // LiDAR unavailable or no confident samples in bounding box
    }

    private struct AnnouncementState {
        var tier: DistanceTier
        var lastAnnounced: Date
    }

    private var announcementState: [ObstacleClass: AnnouncementState] = [:]
    private let announcementInterval: TimeInterval = 4.0

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

    var debugPipeline: DetectionPipeline { pipeline }
    #endif

    init(pipeline: DetectionPipeline, audioArbiter: AudioArbiterService) {
        self.pipeline = pipeline
        self.audioArbiter = audioArbiter
    }

    func start() async throws {
        guard !isRunning else {
            logger.debug("start() — ya en ejecución, noop")
            return
        }
        isRunning = true
        logger.info("start() — isDepthAvailable=\(self.pipeline.frameSource.isDepthAvailable)")
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
        debugState.isFullMode = pipeline.frameSource.isDepthAvailable
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
        announcementState.removeAll()
        #if DEBUG
        debugState.isActive = false
        debugState.fps = 0
        debugState.lastDetections = []
        #endif
        consumptionTask?.cancel()
        consumptionTask = nil
        pipeline.stop()
        audioArbiter.resetSession()
    }

    // MARK: - SCRUM-349: mode announcement

    private func announceMode() {
        guard !pipeline.frameSource.isDepthAvailable else { return }
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
        guard !detections.isEmpty else { return }

        let now = Date()

        // One announcement per obstacle class — take the closest box when YOLO returns multiples.
        var byClass: [ObstacleClass: Detection] = [:]
        for det in detections {
            if let existing = byClass[det.obstacleClass] {
                let existingDist = existing.distanceMeters.map { Double($0) } ?? Double.greatestFiniteMagnitude
                let newDist = det.distanceMeters.map { Double($0) } ?? Double.greatestFiniteMagnitude
                if newDist < existingDist { byClass[det.obstacleClass] = det }
            } else {
                byClass[det.obstacleClass] = det
            }
        }

        for (cls, det) in byClass {
            let tier = distanceTier(for: det)

            let shouldAnnounce: Bool
            if let state = announcementState[cls] {
                let tierChanged = state.tier != tier
                let timedOut = now.timeIntervalSince(state.lastAnnounced) >= announcementInterval
                shouldAnnounce = tierChanged || timedOut
            } else {
                shouldAnnounce = true  // first sighting of this class
            }
            guard shouldAnnounce else { continue }

            announcementState[cls] = AnnouncementState(tier: tier, lastAnnounced: now)

            let text = audioText(for: det, tier: tier)
            let requiresImmediate = tier == .immediate
            let event = SafetyEvent(
                id: UUID(),
                description: text,
                detectedAt: now,
                requiresImmediateAction: requiresImmediate
            )
            onEvent?(event)
            audioArbiter.receive(AudioMessage(
                text: text,
                priority: requiresImmediate ? .immediateRisk : .environmentInformation,
                expiresAt: now.addingTimeInterval(2),
                deduplicationKey: "obstacle-\(cls.rawValue)"
            ))
        }
    }

    // MARK: - Distance helpers

    private func distanceTier(for det: Detection) -> DistanceTier {
        guard let dist = det.distanceMeters else { return .noDistance }
        if dist < 1.0 { return .immediate }
        if dist <= DepthSampler.maxAlertDistanceMeters { return .normal }
        return .far
    }

    private func audioText(for det: Detection, tier: DistanceTier) -> String {
        let cls = spanishName(for: det.obstacleClass)
        switch tier {
        case .immediate, .normal:
            let dist = Double(det.distanceMeters!)
            // Comma as decimal separator so es-MX TTS reads "cero coma tres" not "zero point three".
            let formatted = String(format: "%.1f", dist).replacingOccurrences(of: ".", with: ",")
            return "\(cls) a \(formatted) metros"
        case .far:
            return "\(cls) a más de 4 metros"
        case .noDistance:
            return cls
        }
    }

    private func spanishName(for cls: ObstacleClass) -> String {
        switch cls {
        case .person:        return "persona"
        case .bicycle:       return "bicicleta"
        case .car:           return "carro"
        case .motorcycle:    return "moto"
        case .bus:           return "autobús"
        case .truck:         return "camión"
        case .trafficLight:  return "semáforo"
        case .fireHydrant:   return "hidrante"
        case .stopSign:      return "señal de pare"
        case .parkingMeter:  return "parquímetro"
        case .bench:         return "banca"
        case .chair:         return "silla"
        case .dog:           return "perro"
        case .pottedPlant:   return "planta"
        }
    }
}
#endif
