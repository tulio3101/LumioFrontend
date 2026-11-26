import Foundation

/// SCRUM-44 (reglas del spike SCRUM-309): cuánto antes del punto de giro tiene que oír el
/// usuario la indicación para poder ejecutarlo.
enum TurnGeometry: Equatable {
    /// Esquina o giro cerrado: 1,5 s de reacción.
    case sharp
    /// Curva o giro amplio: 2,5 s de reacción.
    case wide

    var reactionTime: TimeInterval {
        switch self {
        case .sharp: return 1.5
        case .wide: return 2.5
        }
    }
}

/// Lo que el productor de la indicación (Guiar Giros, SCRUM-312) sabe del giro: cuándo
/// llegará el usuario al punto de decisión, según su distancia y su velocidad, y qué tan
/// cerrado es. Con esto el árbitro decide si la indicación puede esperar a que termine la
/// narración o tiene que interrumpirla.
struct TurnDeadline: Equatable {
    let maneuverAt: Date
    let geometry: TurnGeometry

    init(maneuverAt: Date, geometry: TurnGeometry) {
        self.maneuverAt = maneuverAt
        self.geometry = geometry
    }

    /// A partir de la distancia al giro y la velocidad de marcha. Sin velocidad útil (el
    /// usuario está quieto o el GPS no la da) se usa la de una marcha normal.
    init(distanceMeters: Double, speedMetersPerSecond: Double?, geometry: TurnGeometry, now: Date) {
        let speed = speedMetersPerSecond.flatMap { $0 > 0.2 ? $0 : nil } ?? Self.typicalWalkingSpeed
        self.init(maneuverAt: now.addingTimeInterval(max(0, distanceMeters) / speed), geometry: geometry)
    }

    /// Marcha típica de una persona ciega con bastón (m/s). Valor inicial a validar en campo.
    static let typicalWalkingSpeed = 1.0

    /// Último instante en que la indicación puede empezar sin llegar tarde.
    var latestStart: Date { maneuverAt.addingTimeInterval(-geometry.reactionTime) }

    /// La indicación tiene que interrumpir si, al esperar `waiting` segundos a que termine lo
    /// que suena, quedarían ≤ 1,5 s (cerrado) o ≤ 2,5 s (amplio) para el giro.
    func requiresInterruption(waiting: TimeInterval, now: Date) -> Bool {
        maneuverAt.timeIntervalSince(now) - max(0, waiting) <= geometry.reactionTime
    }
}

/// Estima cuánto le falta a una locución. Se queda corto a propósito en la velocidad (habla
/// más lento de lo normal), así la estimación del resto es mayor y la indicación interrumpe
/// antes en lugar de llegar tarde.
struct SpeechDurationEstimator {
    /// Caracteres por segundo de la voz en español a velocidad normal.
    var charactersPerSecond: Double = 13

    func duration(of text: String) -> TimeInterval {
        Double(text.count) / max(1, charactersPerSecond)
    }

    func remaining(of message: AudioMessage, startedAt: Date, now: Date) -> TimeInterval {
        max(0, duration(of: message.text) - now.timeIntervalSince(startedAt))
    }
}
