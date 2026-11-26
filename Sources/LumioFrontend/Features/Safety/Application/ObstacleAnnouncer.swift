import Foundation

/// Convierte los objetos rastreados de cada frame en anuncios de audio. Mantiene el estado por
/// objeto (`TrackedDetection.id`), aplica cooldown por objeto, reanuncia solo cuando el riesgo
/// sube de nivel y silencia los objetos estáticos ya anunciados (SCRUM-33). Numera cada captura
/// (frame) para que `AudioDeduplicationPolicy` descarte capturas viejas. Es un valor puro (sin
/// ARKit ni Core ML), así que se puede probar sin el pipeline.
///
/// SCRUM-34: la proximidad se clasifica con `ProximityPolicy` (tabla del spike SCRUM-309): un
/// objeto en zona de riesgo es una alerta de seguridad P1 (audio y háptica); cerca, sin urgencia,
/// es información P3. Todo corre en el teléfono: no usa red.
struct ObstacleAnnouncer {
    struct Output {
        let event: SafetyEvent
        let message: AudioMessage
    }

    /// Espejo de `DepthSampler.maxAlertDistanceMeters` (que es iOS-only): por encima de este
    /// valor se anuncia "a más de 4 metros".
    static let farThresholdMeters: Float = 4.0

    /// Umbrales de proximidad del spike SCRUM-309 / ADR-307 (SCRUM-34).
    let proximity: ProximityPolicy

    private struct AnnouncementState {
        var level: ProximityLevel
        var lastAnnounced: Date
    }

    let announcementInterval: TimeInterval
    /// Estado por objeto rastreado (no por clase): permite cooldown y escalada por objeto.
    private var announcementState: [Int: AnnouncementState] = [:]
    /// Número de frame. Sube en cada llamada a `announcements`, también sin detecciones.
    private var captureSequence: UInt64 = 0

    init(announcementInterval: TimeInterval = 4.0, proximity: ProximityPolicy = ProximityPolicy()) {
        self.announcementInterval = announcementInterval
        self.proximity = proximity
    }

    /// Procesa los objetos rastreados de un frame y devuelve un anuncio por objeto que supere
    /// la política: primera vez, escalada de nivel, o cooldown vencido mientras se acerca.
    /// `mode` es el sensor de profundidad en uso: cambia los umbrales y si se dicen metros.
    mutating func announcements(
        for tracked: [TrackedDetection], now: Date, mode: DepthMode = .lidar
    ) -> [Output] {
        captureSequence += 1
        guard !tracked.isEmpty else { return [] }

        var outputs: [Output] = []
        for obj in tracked {
            let reading = proximity.reading(
                distance: obj.detection.distanceMeters, isApproaching: obj.isApproaching, mode: mode
            )
            guard shouldAnnounce(obj, level: reading.level, now: now) else { continue }
            announcementState[obj.id] = AnnouncementState(level: reading.level, lastAnnounced: now)

            let text = audioText(for: obj.detection, reading: reading, mode: mode)
            let immediate = reading.level == .urgent
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
    ///
    /// Anti-repetición (SCRUM-34): el estado guarda el nivel más alto ya anunciado de cada objeto,
    /// así que una distancia que fluctúa alrededor de un umbral no repite la alerta; solo vuelve a
    /// sonar si el objeto se sigue acercando y venció el cooldown.
    private func shouldAnnounce(_ obj: TrackedDetection, level: ProximityLevel, now: Date) -> Bool {
        guard let state = announcementState[obj.id] else { return true }  // primera vez
        if rank(level) > rank(state.level) { return true }                // subió de nivel
        if obj.isApproaching, now.timeIntervalSince(state.lastAnnounced) >= announcementInterval {
            return true
        }
        return false
    }

    /// Urgencia relativa de cada nivel, para detectar escaladas (cerca → zona de riesgo).
    private func rank(_ level: ProximityLevel) -> Int {
        switch level {
        case .unknown: return 0
        case .far:     return 1
        case .near:    return 2
        case .urgent:  return 3
        }
    }

    /// Formatea una distancia con coma decimal para el TTS es-MX ("cero coma tres").
    static func formatMeters(_ dist: Float) -> String {
        String(format: "%.1f", Double(dist)).replacingOccurrences(of: ".", with: ",")
    }

    /// SCRUM-33: anuncio de un obstáculo detectado por profundidad (sin clase YOLO). La
    /// persistencia y el cooldown ya los aplicó el pipeline (`PersistenceGate`), así que aquí solo
    /// se construye el mensaje. Ej.: "pared al frente, a 1,0 metros".
    func depthObstacleOutput(kind: DepthObstacleKind, distanceMeters: Float, now: Date) -> Output {
        // Solo existe con LiDAR (la profundidad del corredor), y un muro o una mesa no se mueven.
        let reading = proximity.reading(distance: distanceMeters, isApproaching: false, mode: .lidar)
        let immediate = reading.level == .urgent
        let text = reading.speaksMeters
            ? "\(kind.spanishName) al frente, a \(Self.formatMeters(distanceMeters)) metros"
            : "\(kind.spanishName) al frente, cerca"
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

    /// Texto del aviso. Con LiDAR dice los metros solo hasta 3 m (ADR-307): de 3 a 4 m dice
    /// «cerca». En modo reducido nunca dice metros: «muy cerca» o «cerca».
    private func audioText(for det: Detection, reading: ProximityReading, mode: DepthMode) -> String {
        let cls = Self.spanishName(for: det.obstacleClass)
        switch (mode, reading.level) {
        case (.reduced, .urgent):
            return "\(cls) muy cerca"
        case (.reduced, .near):
            return "\(cls) cerca"
        case (_, .urgent), (_, .near):
            guard reading.speaksMeters, let dist = det.distanceMeters else { return "\(cls) cerca" }
            // Coma como separador decimal para que el TTS es-MX lea "cero coma tres".
            return "\(cls) a \(Self.formatMeters(dist)) metros"
        case (_, .far):
            return "\(cls) a más de 4 metros"
        case (_, .unknown):
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
