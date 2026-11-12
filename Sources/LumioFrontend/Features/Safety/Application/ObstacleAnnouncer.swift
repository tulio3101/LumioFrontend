import Foundation

/// Convierte las detecciones de cada frame en anuncios de audio. Mantiene el throttle por
/// clase y numera cada captura (frame) para que `AudioDeduplicationPolicy` descarte las
/// capturas viejas y las repetidas. Es un valor puro (sin ARKit ni Core ML), así que se puede
/// probar sin el pipeline.
struct ObstacleAnnouncer {
    struct Output {
        let event: SafetyEvent
        let message: AudioMessage
    }

    enum DistanceTier: Equatable {
        case immediate   // < 1 m — interrumpe con .immediateRisk
        case normal      // 1–4 m — .environmentInformation
        case far         // > 4 m — "a más de 4 metros"
        case noDistance  // sin LiDAR o sin muestras fiables en la caja
    }

    /// Espejo de `DepthSampler.maxAlertDistanceMeters` (que es iOS-only): por encima de este
    /// valor se anuncia "a más de 4 metros".
    static let farThresholdMeters: Float = 4.0

    private struct AnnouncementState {
        var tier: DistanceTier
        var lastAnnounced: Date
    }

    let announcementInterval: TimeInterval
    private var announcementState: [ObstacleClass: AnnouncementState] = [:]
    /// Número de frame. Sube en cada llamada a `announcements`, también sin detecciones.
    private var captureSequence: UInt64 = 0

    init(announcementInterval: TimeInterval = 4.0) {
        self.announcementInterval = announcementInterval
    }

    /// Procesa las detecciones de un frame y devuelve un anuncio por clase que supere el
    /// throttle (cambió el tramo de distancia o pasó `announcementInterval`).
    mutating func announcements(for detections: [Detection], now: Date) -> [Output] {
        captureSequence += 1
        guard !detections.isEmpty else { return [] }

        // Un anuncio por clase: la caja más cercana cuando YOLO devuelve varias.
        var byClass: [ObstacleClass: Detection] = [:]
        for det in detections {
            if let existing = byClass[det.obstacleClass] {
                let existingDist = existing.distanceMeters.map(Double.init) ?? .greatestFiniteMagnitude
                let newDist = det.distanceMeters.map(Double.init) ?? .greatestFiniteMagnitude
                if newDist < existingDist { byClass[det.obstacleClass] = det }
            } else {
                byClass[det.obstacleClass] = det
            }
        }

        var outputs: [Output] = []
        for (cls, det) in byClass {
            let tier = distanceTier(for: det)

            let shouldAnnounce: Bool
            if let state = announcementState[cls] {
                shouldAnnounce = state.tier != tier
                    || now.timeIntervalSince(state.lastAnnounced) >= announcementInterval
            } else {
                shouldAnnounce = true  // primera vez que se ve esta clase
            }
            guard shouldAnnounce else { continue }
            announcementState[cls] = AnnouncementState(tier: tier, lastAnnounced: now)

            let text = audioText(for: det, tier: tier)
            let immediate = tier == .immediate
            outputs.append(Output(
                event: SafetyEvent(
                    id: UUID(), description: text, detectedAt: now, requiresImmediateAction: immediate
                ),
                message: AudioMessage(
                    text: text,
                    priority: immediate ? .immediateRisk : .environmentInformation,
                    expiresAt: now.addingTimeInterval(2),
                    contextID: SafetyAudio.context,
                    deduplicationKey: "obstacle-\(cls.rawValue)",
                    captureSequence: captureSequence
                )
            ))
        }
        return outputs
    }

    func distanceTier(for det: Detection) -> DistanceTier {
        guard let dist = det.distanceMeters else { return .noDistance }
        if dist < 1.0 { return .immediate }
        if dist <= Self.farThresholdMeters { return .normal }
        return .far
    }

    private func audioText(for det: Detection, tier: DistanceTier) -> String {
        let cls = Self.spanishName(for: det.obstacleClass)
        switch tier {
        case .immediate, .normal:
            let dist = Double(det.distanceMeters!)
            // Coma como separador decimal para que el TTS es-MX lea "cero coma tres".
            let formatted = String(format: "%.1f", dist).replacingOccurrences(of: ".", with: ",")
            return "\(cls) a \(formatted) metros"
        case .far:
            return "\(cls) a más de 4 metros"
        case .noDistance:
            return cls
        }
    }

    static func spanishName(for cls: ObstacleClass) -> String {
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
        case .diningTable:   return "mesa"
        case .bed:           return "cama"
        case .couch:         return "sofá"
        case .toilet:        return "inodoro"
        case .refrigerator:  return "nevera"
        case .tv:            return "televisor"
        case .laptop:        return "portátil"
        case .suitcase:      return "maleta"
        case .backpack:      return "mochila"
        case .umbrella:      return "sombrilla"
        }
    }
}
