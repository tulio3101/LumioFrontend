import CoreGraphics

/// Una `Detection` asociada a un objeto rastreado con ID estable entre frames.
/// La producen `ObstacleTracker` + `WalkingCorridor` antes del anuncio, para que las alertas
/// sean por objeto (no por frame) y puedan ponderar el acercamiento (SCRUM-33).
struct TrackedDetection: Equatable {
    /// ID estable mientras el objeto se siga viendo; se libera al olvidarlo (ver `ObstacleTracker`).
    let id: Int
    let detection: Detection
    /// true cuando la distancia al objeto viene decreciendo (se acerca). Requiere profundidad;
    /// false si no hay distancia (modo reducido) o si está estático/alejándose.
    let isApproaching: Bool

    var obstacleClass: ObstacleClass { detection.obstacleClass }
    var boundingBox: CGRect { detection.boundingBox }
    var distanceMeters: Float? { detection.distanceMeters }
}
