import CoreGraphics
import Foundation

/// Parámetros del "foco de detección": rastreo por objeto, corredor de marcha, persistencia,
/// acercamiento e inclinación del teléfono. Un único lugar para ajustar el comportamiento sin
/// tocar la lógica (SCRUM-33). Todas las coordenadas son normalizadas 0…1, origen arriba-izquierda.
struct DetectionFocusConfig: Equatable {
    // MARK: Rastreo (IoU) e IDs estables
    /// IoU mínima para considerar que una detección es el mismo objeto que un track existente.
    var iouMatchThreshold: Float = 0.3
    /// Frames consecutivos sin ver un objeto antes de olvidarlo (su ID se libera).
    var maxMissedFrames: Int = 5

    // MARK: Persistencia
    /// El objeto debe aparecer en `minAppearances` de los últimos `windowFrames` frames antes de alertar.
    var minAppearances: Int = 3
    var windowFrames: Int = 5

    // MARK: Corredor de marcha
    /// Fracción central del ancho que se considera "en el camino" (0.40 = 40% central).
    var corridorWidthFraction: CGFloat = 0.40
    /// Borde superior de la franja (0.5 = mitad inferior de la imagen).
    var corridorVerticalStart: CGFloat = 0.5
    /// Desplazamiento vertical de la franja por grado de inclinación (compensa apuntar arriba/abajo).
    var corridorShiftPerDegree: CGFloat = 0.01

    // MARK: Inclinación (pitch en grados; 0 = horizonte, + mira arriba, − mira abajo)
    var minPitchDegrees: Float = -35
    var maxPitchDegrees: Float = 35
    /// Segundos entre recordatorios de "levanta/baja el teléfono".
    var pitchReminderCooldown: TimeInterval = 6.0

    // MARK: Acercamiento y proximidad
    /// Cuánto debe bajar la distancia (m) entre frames para contar como "se acerca".
    var approachingDeltaMeters: Float = 0.15
    /// SCRUM-34: umbrales de proximidad del spike SCRUM-309 / ADR-307 (zona de riesgo P1, "cerca"
    /// y modo reducido sin LiDAR). Reemplaza al antiguo umbral único de 1 m.
    var proximity = ProximityPolicy()

    // MARK: Anuncio por objeto
    /// Tiempo mínimo entre anuncios del mismo objeto rastreado (cuando se sigue acercando).
    var perTrackCooldownSeconds: TimeInterval = 4.0

    // MARK: Obstáculos por profundidad (independientes de la clase) y desniveles
    /// Un obstáculo por profundidad / desnivel debe aparecer en `depthMinAppearances` de los
    /// últimos `depthWindowFrames` frames antes de alertar (filtra ruido de un solo frame).
    var depthMinAppearances: Int = 3
    var depthWindowFrames: Int = 5
    /// Tiempo mínimo entre anuncios del mismo tipo de obstáculo/desnivel por profundidad.
    var depthCooldownSeconds: TimeInterval = 4.0
    /// Altura (m) sobre el plano de piso por debajo de la cual un punto se considera "piso" y se
    /// descarta al buscar obstáculos (no es un obstáculo, es el suelo).
    var floorBandMeters: Float = 0.12
    /// Zona del corredor analizada para desniveles (metros adelante del usuario). `near` bajo
    /// (0.3 m) para ver una escalera de bajada que arranca justo en el borde bajo los pies.
    var elevationNearMeters: Float = 0.3
    var elevationFarMeters: Float = 3.0
    /// Una subida solo es escalón si va seguida de una huella plana de al menos esta distancia a la
    /// nueva altura; si no, es una pared/zócalo (SCRUM-33, corrección de falso escalón).
    var minTreadMeters: Float = 0.20
    /// Al muestrear el perfil se descartan puntos por encima de este techo sobre el piso: son
    /// paredes/mobiliario alto, no desniveles del suelo.
    var elevationCeilingMeters: Float = 0.4
    /// Rango (m) por debajo de la cámara donde debe estar el plano del piso "bajo los pies".
    var floorUnderFeetMinMeters: Float = 0.9
    var floorUnderFeetMaxMeters: Float = 1.8
    /// Muestras de piso válido (confianza alta) que deben preceder a un hueco para confirmarlo
    /// como bajada/bordillo, y longitud mínima del hueco. Evita interpretar reflejos/vidrio/sol.
    var minFloorSamplesBeforeDrop: Int = 3
    var minHoleRun: Int = 2
    /// Caída (m) respecto al plano de piso que confirma un escalón/bordillo hacia abajo.
    var dropStepMeters: Float = 0.10
    /// Subida (m) que confirma un escalón hacia arriba.
    var riseStepMeters: Float = 0.10
    /// Rango de altura (m) de un escalón real (subida o bajada). Un cambio menor que `stepMin` es
    /// ruido/rampa; uno mayor que `stepMax` NO es escalón/escalera (es una pared/obstáculo, lo
    /// maneja `DepthObstacleDetector`). Valores típicos de escalón peatonal: 8–25 cm.
    var stepMinMeters: Float = 0.08
    var stepMaxMeters: Float = 0.25
    /// SCRUM-33 (endurecido): un bordillo/escalón hacia abajo (una sola caída) solo se avisa si la
    /// caída está en [curbMinDrop, curbMaxDrop], hubo piso plano ≥ `curbFlatFloorBefore` antes y
    /// está a menos de `curbMaxDistance`. Las escaleras (varias caídas) no tienen estas restricciones.
    var curbMinDropMeters: Float = 0.10
    var curbMaxDropMeters: Float = 0.25
    var curbFlatFloorBeforeMeters: Float = 0.25
    var curbMaxDistanceMeters: Float = 2.0
    /// Persistencia específica de los desniveles: más estricta que la de profundidad (5 de 7).
    var elevationMinAppearances: Int = 5
    var elevationWindowFrames: Int = 7
    /// Margen (m) bajo la cámara para considerar que un plano horizontal es "el piso" (y no una
    /// mesa). El plano de piso es el más cercano por debajo de la cámara menos este margen.
    var floorBelowCameraMargin: Float = 0.5
    /// Un objeto cuya caja ocupe al menos esta fracción de alto se conserva aunque esté en el
    /// borde del corredor: está cerca/parcialmente visible y no debe descartarse (SCRUM-33).
    var corridorKeepLargeBoxHeightFraction: CGFloat = 0.5

    init() {}
}
