import CoreGraphics

/// Una detección de obstáculo producida por el pipeline YOLO26n 640 INT8.
/// Todas las coordenadas están normalizadas (0…1), con origen arriba-izquierda.
struct Detection: Equatable {
    let obstacleClass: ObstacleClass
    let confidence: Float
    /// Bounding box normalizado, origen arriba-izquierda (0…1 en cada eje).
    /// Vision usa origen abajo-izquierda; el decoder debe convertir antes de poblar este campo.
    let boundingBox: CGRect
    /// Distancia estimada al obstáculo en metros. nil hasta que DepthSampler la enriquezca.
    var distanceMeters: Float?
}
