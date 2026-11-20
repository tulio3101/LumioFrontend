import CoreGraphics

/// Fusiona el obstáculo por profundidad con las detecciones de YOLO para no anunciar dos veces el
/// mismo obstáculo. Si una caja YOLO (ya filtrada al corredor) cubre la columna del obstáculo de
/// profundidad, **gana el nombre de YOLO** y se suprime el genérico.
enum DepthObstacleFusion {
    /// true si alguna caja YOLO cubre horizontalmente el centro del obstáculo de profundidad.
    /// Las cajas están en coordenadas normalizadas (origen arriba-izquierda), como `Detection`.
    static func isCoveredByYOLO(
        _ hit: DepthObstacleHit,
        yoloBoxes: [CGRect]
    ) -> Bool {
        let x = CGFloat(hit.centerXFraction)
        return yoloBoxes.contains { box in
            x >= box.minX && x <= box.maxX
        }
    }

    /// Decide si el obstáculo de profundidad se anuncia. Devuelve nil cuando YOLO ya lo cubre.
    static func survivingObstacle(
        _ hit: DepthObstacleHit?,
        kind: DepthObstacleKind,
        yoloBoxes: [CGRect]
    ) -> (hit: DepthObstacleHit, kind: DepthObstacleKind)? {
        guard let hit else { return nil }
        guard !isCoveredByYOLO(hit, yoloBoxes: yoloBoxes) else { return nil }
        return (hit, kind)
    }
}
