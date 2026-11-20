/// Un obstáculo detectado por profundidad listo para anunciar (ya pasó corredor, fusión con YOLO,
/// persistencia y cooldown en el pipeline).
struct DepthObstacleSignal: Equatable {
    let kind: DepthObstacleKind
    let distanceMeters: Float
}

/// Salida del pipeline por frame: las detecciones YOLO rastreadas más los obstáculos detectados
/// por profundidad (independientes de la clase). En la Parte 3 se añadirán los desniveles.
struct SafetyFrameOutput: Equatable {
    var tracked: [TrackedDetection]
    var depthObstacles: [DepthObstacleSignal]

    init(tracked: [TrackedDetection] = [], depthObstacles: [DepthObstacleSignal] = []) {
        self.tracked = tracked
        self.depthObstacles = depthObstacles
    }
}
