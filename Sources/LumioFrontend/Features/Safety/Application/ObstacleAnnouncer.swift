import Foundation

/// Convierte los objetos rastreados de cada frame en anuncios de audio. Mantiene el estado por
/// objeto (`TrackedDetection.id`), aplica cooldown por objeto, reanuncia solo cuando el riesgo
/// sube de nivel y silencia los objetos estáticos ya anunciados (SCRUM-33). Numera cada captura
/// (frame) para que `AudioDeduplicationPolicy` descarte capturas viejas. Es un valor puro (sin
/// ARKit ni Core ML), así que se puede probar sin el pipeline.
struct ObstacleAnnouncer {
    struct Output {
        let event: SafetyEvent
        let message: AudioMessage
    }

    enum DistanceTier: Equatable {
        case immediate   // < 1 m — interrumpe con .immediateRisk (nivel peligro)
        case normal      // 1–4 m — .environmentInformation
        case far         // > 4 m — "a más de 4 metros"
        case noDistance  // sin LiDAR o sin muestras fiables en la caja
    }

    /// Espejo de `DepthSampler.maxAlertDistanceMeters` (que es iOS-only): por encima de este
    /// valor se anuncia "a más de 4 metros".
    static let farThresholdMeters: Float = 4.0

    /// Distancia (m) por debajo de la cual un objeto es peligro: reanuncia aunque esté quieto.
    let dangerDistanceMeters: Float

    private struct AnnouncementState {
        var tier: DistanceTier
        var lastAnnounced: Date
    }

    let announcementInterval: TimeInterval
    /// Estado por objeto rastreado (no por clase): permite cooldown y escalada por objeto.
    private var announcementState: [Int: AnnouncementState] = [:]
    /// Número de frame. Sube en cada llamada a `announcements`, también sin detecciones.
    private var captureSequence: UInt64 = 0

    init(announcementInterval: TimeInterval = 4.0, dangerDistanceMeters: Float = 1.0) {
        self.announcementInterval = announcementInterval
        self.dangerDistanceMeters = dangerDistanceMeters
    }

    /// Procesa los objetos rastreados de un frame y devuelve un anuncio por objeto que supere
    /// la política: primera vez, escalada de nivel, o cooldown vencido mientras se acerca.
    mutating func announcements(for tracked: [TrackedDetection], now: Date) -> [Output] {
        captureSequence += 1
        guard !tracked.isEmpty else { return [] }

        var outputs: [Output] = []
        for obj in tracked {
            let tier = distanceTier(for: obj.detection)
            guard shouldAnnounce(obj, tier: tier, now: now) else { continue }
            announcementState[obj.id] = AnnouncementState(tier: tier, lastAnnounced: now)

            let text = audioText(for: obj.detection, tier: tier)
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
                    deduplicationKey: "obstacle-\(obj.obstacleClass.rawValue)-\(obj.id)",
                    captureSequence: captureSequence
                )
            ))
        }
        return outputs
    }

    /// Anuncia si: es la primera vez que se ve el objeto, el nivel subió (escalada), o se sigue
    /// acercando y venció el cooldown. Un objeto estático ya anunciado se silencia.
    private func shouldAnnounce(_ obj: TrackedDetection, tier: DistanceTier, now: Date) -> Bool {
        guard let state = announcementState[obj.id] else { return true }  // primera vez
        if rank(tier) > rank(state.tier) { return true }                  // subió de nivel
        if obj.isApproaching, now.timeIntervalSince(state.lastAnnounced) >= announcementInterval {
            return true
        }
        return false
    }

    /// Urgencia relativa de cada tramo, para detectar escaladas (alerta → peligro).
    private func rank(_ tier: DistanceTier) -> Int {
        switch tier {
        case .noDistance: return 0
        case .far:        return 1
        case .normal:     return 2
        case .immediate:  return 3
        }
    }

    func distanceTier(for det: Detection) -> DistanceTier {
        tier(forMeters: det.distanceMeters)
    }

    func tier(forMeters dist: Float?) -> DistanceTier {
        guard let dist else { return .noDistance }
        if dist < dangerDistanceMeters { return .immediate }
        if dist <= Self.farThresholdMeters { return .normal }
        return .far
    }

    /// Formatea una distancia con coma decimal para el TTS es-MX ("cero coma tres").
    static func formatMeters(_ dist: Float) -> String {
        String(format: "%.1f", Double(dist)).replacingOccurrences(of: ".", with: ",")
    }

    /// SCRUM-33: anuncio de un obstáculo detectado por profundidad (sin clase YOLO). La
    /// persistencia y el cooldown ya los aplicó el pipeline (`PersistenceGate`), así que aquí solo
    /// se construye el mensaje. Ej.: "pared al frente, a 1,0 metros".
    func depthObstacleOutput(kind: DepthObstacleKind, distanceMeters: Float, now: Date) -> Output {
        let tier = tier(forMeters: distanceMeters)
        let immediate = tier == .immediate
        let text = "\(kind.spanishName) al frente, a \(Self.formatMeters(distanceMeters)) metros"
        return Output(
            event: SafetyEvent(
                id: UUID(), description: text, detectedAt: now, requiresImmediateAction: immediate
            ),
            message: AudioMessage(
                text: text,
                priority: immediate ? .immediateRisk : .environmentInformation,
                expiresAt: now.addingTimeInterval(2),
                contextID: SafetyAudio.context,
                deduplicationKey: "depth-\(kind.rawValue)"
            )
        )
    }

    /// SCRUM-33: anuncio de un desnivel (escalón/escalera/bordillo/rampa). La persistencia y el
    /// cooldown ya los aplicó el pipeline. nil para `flat`.
    func elevationOutput(for hazard: ElevationHazard, now: Date) -> Output? {
        guard let a = ElevationAudio.announcement(for: hazard) else { return nil }
        let immediate = a.priority == .immediateRisk
        return Output(
            event: SafetyEvent(
                id: UUID(), description: a.text, detectedAt: now, requiresImmediateAction: immediate
            ),
            message: AudioMessage(
                text: a.text,
                priority: a.priority,
                expiresAt: now.addingTimeInterval(2),
                contextID: SafetyAudio.context,
                deduplicationKey: "elevation-\(a.typeKey)"
            )
        )
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
        case .suitcase:      return "maleta"
        case .backpack:      return "mochila"
        case .umbrella:      return "sombrilla"
        }
    }
}
