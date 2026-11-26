/// Un obstáculo detectado por profundidad listo para anunciar (ya pasó corredor, fusión con YOLO,
/// persistencia y cooldown en el pipeline).
struct DepthObstacleSignal: Equatable {
    let kind: DepthObstacleKind
    let distanceMeters: Float
}

/// Un desnivel listo para anunciar (ya pasó persistencia + cooldown en el pipeline). `isDanger`
/// (bajada) dispara la háptica de peligro.
struct ElevationHazardSignal: Equatable {
    let hazard: ElevationHazard
    let isDanger: Bool
}

/// Salida del pipeline por frame: detecciones YOLO rastreadas, obstáculos por profundidad y
/// desniveles (escalón/escalera/bordillo/rampa).
struct SafetyFrameOutput: Equatable {
    var tracked: [TrackedDetection]
    var depthObstacles: [DepthObstacleSignal]
    var elevationHazards: [ElevationHazardSignal]
    /// SCRUM-321: señal de TRANSICIÓN de pausa térmica. nil = sin cambio; true = la detección
    /// acaba de pausarse por calor crítico; false = acaba de reanudarse al enfriar. Solo se emite
    /// en el frame del cambio, así SafetyService avisa una sola vez por episodio.
    var thermalPaused: Bool?
    #if DEBUG
    /// Diagnóstico del frame (solo Debug): perfil, piso, hazard crudo, YOLO crudas. nil en frames
    /// sin datos (p. ej. inclinación fuera de rango).
    var debug: SafetyDebugFrame?
    #endif

    init(
        tracked: [TrackedDetection] = [],
        depthObstacles: [DepthObstacleSignal] = [],
        elevationHazards: [ElevationHazardSignal] = [],
        thermalPaused: Bool? = nil
    ) {
        self.tracked = tracked
        self.depthObstacles = depthObstacles
        self.elevationHazards = elevationHazards
        self.thermalPaused = thermalPaused
    }
}
