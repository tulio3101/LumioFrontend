/// Instantánea de diagnóstico por frame (SCRUM-33, solo Debug): perfil de alturas, piso, pitch,
/// hazard crudo vs. anunciado y detecciones YOLO CRUDAS (antes de ClassConfidencePolicy/corredor/
/// persistencia). Codable para poder grabar casos reales a JSON y convertirlos en tests. Valor puro.
struct SafetyDebugFrame: Codable, Equatable {
    struct RawDetection: Codable, Equatable {
        var cls: String
        var confidence: Float
    }

    var timestamp: Double
    var pitchDegrees: Float?
    /// Piso elegido (world Y) y altura de la cámara sobre ese piso.
    var floorHeight: Float?
    var cameraHeightAboveFloor: Float?
    /// Perfil por bin: distancia adelante y altura (nil = hueco sin lecturas confiables).
    var profileForward: [Float]
    var profileHeights: [Float?]
    /// Desnivel ANTES de persistencia (lo que vio el analizador este frame).
    var rawHazard: String
    /// Desniveles anunciados (tras persistencia + cooldown).
    var announcedHazards: [String]
    /// Detecciones YOLO crudas (clase + confianza) antes de cualquier filtro.
    var rawDetections: [RawDetection]
    /// Conteos tras los filtros, para comparar con las crudas ("0 objeto(s)").
    var trackedCount: Int
    var depthObstacleCount: Int

    init(
        timestamp: Double = 0, pitchDegrees: Float? = nil, floorHeight: Float? = nil,
        cameraHeightAboveFloor: Float? = nil, profileForward: [Float] = [],
        profileHeights: [Float?] = [], rawHazard: String = "plano", announcedHazards: [String] = [],
        rawDetections: [RawDetection] = [], trackedCount: Int = 0, depthObstacleCount: Int = 0
    ) {
        self.timestamp = timestamp
        self.pitchDegrees = pitchDegrees
        self.floorHeight = floorHeight
        self.cameraHeightAboveFloor = cameraHeightAboveFloor
        self.profileForward = profileForward
        self.profileHeights = profileHeights
        self.rawHazard = rawHazard
        self.announcedHazards = announcedHazards
        self.rawDetections = rawDetections
        self.trackedCount = trackedCount
        self.depthObstacleCount = depthObstacleCount
    }
}

extension ElevationHazard {
    /// Etiqueta corta para el panel de debug y el JSON grabado.
    var debugLabel: String {
        switch self {
        case .flat: return "plano"
        case .rampUp(let d): return "rampa↑ \(fmt(d))m"
        case .rampDown(let d): return "rampa↓ \(fmt(d))m"
        case .stepUp(let d): return "escalón↑ \(fmt(d))m"
        case .stairsUp(let d): return "escalera↑ \(fmt(d))m"
        case .stepDownOrCurb(let d): return "bordillo/escalón↓ \(fmt(d))m"
        case .stairsDown(let d): return "escalera↓ \(fmt(d))m"
        }
    }
    private func fmt(_ v: Float) -> String { String(format: "%.1f", v) }
}
