import CoreGraphics

/// Estado de la inclinación del teléfono respecto al rango útil para detectar.
enum PitchState: Equatable {
    case tooLow   // la cámara apunta demasiado al piso → hay que levantar el teléfono
    case ok
    case tooHigh  // la cámara apunta demasiado al cielo → hay que bajar el teléfono
}

/// Clasifica el pitch (grados) contra el rango válido de la configuración.
func pitchState(_ pitchDegrees: Float, minDegrees: Float, maxDegrees: Float) -> PitchState {
    if pitchDegrees < minDegrees { return .tooLow }
    if pitchDegrees > maxDegrees { return .tooHigh }
    return .ok
}

/// Corredor de marcha: la franja central-inferior de la imagen donde un obstáculo está
/// "en el camino". Valor puro y testeable (sin ARKit). La franja se desplaza verticalmente
/// según la inclinación (pitch) para compensar que el teléfono apunte más arriba o más abajo.
/// Coordenadas normalizadas 0…1, origen arriba-izquierda (igual que `Detection.boundingBox`).
struct WalkingCorridor {
    let widthFraction: CGFloat
    let verticalStart: CGFloat
    let shiftPerDegree: CGFloat

    init(widthFraction: CGFloat, verticalStart: CGFloat, shiftPerDegree: CGFloat = 0) {
        self.widthFraction = widthFraction
        self.verticalStart = verticalStart
        self.shiftPerDegree = shiftPerDegree
    }

    init(config: DetectionFocusConfig) {
        self.init(
            widthFraction: config.corridorWidthFraction,
            verticalStart: config.corridorVerticalStart,
            shiftPerDegree: config.corridorShiftPerDegree
        )
    }

    /// Rectángulo del corredor para un pitch dado (grados). Apuntar más arriba (+) baja la
    /// franja; apuntar más abajo (−) la sube, para seguir cubriendo el suelo frente al usuario.
    func rect(pitchDegrees: Float = 0) -> CGRect {
        let halfWidth = widthFraction / 2
        let xMin = 0.5 - halfWidth
        let start = min(max(verticalStart + CGFloat(pitchDegrees) * shiftPerDegree, 0), 0.95)
        return CGRect(x: xMin, y: start, width: widthFraction, height: 1 - start)
    }

    /// true si la caja intersecta el corredor (está "en el camino").
    func contains(_ box: CGRect, pitchDegrees: Float = 0) -> Bool {
        box.intersects(rect(pitchDegrees: pitchDegrees))
    }
}
