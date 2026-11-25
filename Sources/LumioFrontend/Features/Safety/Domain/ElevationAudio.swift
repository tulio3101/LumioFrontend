/// Mapea un `ElevationHazard` a su anuncio: texto en español, prioridad del AudioArbiter, si es
/// peligro (bajada → háptica fuerte) y una clave de tipo (dedupe + persistencia). Valor puro.
struct ElevationAnnouncement: Equatable {
    let text: String
    let priority: AudioPriority
    /// true para bajadas (lo más crítico): dispara la háptica de peligro.
    let isDanger: Bool
    /// Clave estable del tipo de peligro, para dedupe en audio y persistencia (N-de-M + cooldown).
    let typeKey: String
}

enum ElevationAudio {
    /// nil para `flat` (no se anuncia). Las bajadas y los escalones son `immediateRisk`; las
    /// rampas son información del entorno.
    static func announcement(for hazard: ElevationHazard) -> ElevationAnnouncement? {
        switch hazard {
        case .flat:
            return nil
        case .stairsDown(let d):
            return .init(text: "escalera hacia abajo, a \(meters(d)) metros",
                         priority: .immediateRisk, isDanger: true, typeKey: "stairs-down")
        case .stepDownOrCurb(let d):
            return .init(text: "escalón hacia abajo, a \(meters(d)) metros",
                         priority: .immediateRisk, isDanger: true, typeKey: "step-down")
        case .stepUp(let d):
            return .init(text: "escalón hacia arriba, a \(meters(d)) metros",
                         priority: .immediateRisk, isDanger: false, typeKey: "step-up")
        case .stairsUp(let d):
            return .init(text: "escaleras hacia arriba, a \(meters(d)) metros",
                         priority: .immediateRisk, isDanger: false, typeKey: "stairs-up")
        case .rampUp(let d):
            return .init(text: "rampa hacia arriba, a \(meters(d)) metros",
                         priority: .environmentInformation, isDanger: false, typeKey: "ramp-up")
        case .rampDown(let d):
            return .init(text: "rampa hacia abajo, a \(meters(d)) metros",
                         priority: .environmentInformation, isDanger: false, typeKey: "ramp-down")
        }
    }

    /// Distancia con coma decimal para el TTS es-MX ("a uno coma cinco metros").
    private static func meters(_ d: Float) -> String {
        String(format: "%.1f", Double(d)).replacingOccurrences(of: ".", with: ",")
    }
}
