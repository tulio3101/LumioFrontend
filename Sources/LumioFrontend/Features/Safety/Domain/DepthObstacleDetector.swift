/// Rejilla de profundidad del corredor de marcha, ya proyectada por el adaptador iOS. Valor puro
/// y testeable: cada celda tiene su profundidad (m) y si pertenece al piso (para descontarlo).
/// Las columnas cubren el ancho normalizado 0…1 de izquierda a derecha.
struct CorridorDepthGrid: Equatable {
    let rows: Int
    let cols: Int
    /// Profundidad en metros, row-major. `<= 0` o `.nan` = inválida (sin lectura confiable).
    let depth: [Float]
    /// true si la celda es piso (se descuenta: el suelo no es un obstáculo).
    let floor: [Bool]

    init(rows: Int, cols: Int, depth: [Float], floor: [Bool]) {
        self.rows = rows
        self.cols = cols
        self.depth = depth
        self.floor = floor
    }

    func depthAt(_ r: Int, _ c: Int) -> Float { depth[r * cols + c] }
    func isFloorAt(_ r: Int, _ c: Int) -> Bool { floor[r * cols + c] }
    /// Fracción de ancho (0…1) del centro de la columna c.
    func columnFraction(_ c: Int) -> Float { (Float(c) + 0.5) / Float(cols) }
}

/// Obstáculo detectado por profundidad: su distancia y dónde está (fracción de ancho).
struct DepthObstacleHit: Equatable {
    let distance: Float
    let centerXFraction: Float
}

/// Detector de obstáculos independiente de la clase: busca la **distancia mínima confiable** en la
/// franja central del corredor, descontando el piso. Exige un grupo mínimo de celdas cercanas para
/// no disparar con un píxel ruidoso. Avisa aunque YOLO no haya detectado nada.
struct DepthObstacleDetector {
    /// Por encima de esta distancia no se considera obstáculo del camino.
    let maxAlertDistance: Float
    /// Franja central del ancho a analizar (0…1); fuera de esto es "lateral" y se ignora.
    let corridorXRange: ClosedRange<Float>
    /// Celdas cercanas mínimas (dentro de `depthTolerance` del mínimo) para confirmar un obstáculo.
    let minClusterCells: Int
    /// Tolerancia (m) para agrupar celdas a la misma distancia del obstáculo.
    let depthTolerance: Float

    init(
        maxAlertDistance: Float = 4.0,
        corridorXRange: ClosedRange<Float> = 0.3...0.7,
        minClusterCells: Int = 6,
        depthTolerance: Float = 0.3
    ) {
        self.maxAlertDistance = maxAlertDistance
        self.corridorXRange = corridorXRange
        self.minClusterCells = minClusterCells
        self.depthTolerance = depthTolerance
    }

    func detect(_ grid: CorridorDepthGrid) -> DepthObstacleHit? {
        guard grid.rows > 0, grid.cols > 0 else { return nil }

        // Candidatos: celdas válidas, no-piso, dentro de la franja central y bajo el umbral.
        var nearest: Float = .greatestFiniteMagnitude
        for r in 0..<grid.rows {
            for c in 0..<grid.cols where corridorXRange.contains(grid.columnFraction(c)) {
                guard !grid.isFloorAt(r, c) else { continue }
                let d = grid.depthAt(r, c)
                guard d > 0, d.isFinite, d <= maxAlertDistance else { continue }
                if d < nearest { nearest = d }
            }
        }
        guard nearest.isFinite, nearest <= maxAlertDistance else { return nil }

        // Confirmar con un grupo de celdas a la misma distancia (no un píxel suelto).
        var clusterCount = 0
        var sumX: Float = 0
        for r in 0..<grid.rows {
            for c in 0..<grid.cols where corridorXRange.contains(grid.columnFraction(c)) {
                guard !grid.isFloorAt(r, c) else { continue }
                let d = grid.depthAt(r, c)
                guard d > 0, d.isFinite, d - nearest <= depthTolerance else { continue }
                clusterCount += 1
                sumX += grid.columnFraction(c)
            }
        }
        guard clusterCount >= minClusterCells else { return nil }
        return DepthObstacleHit(distance: nearest, centerXFraction: sumX / Float(clusterCount))
    }
}
