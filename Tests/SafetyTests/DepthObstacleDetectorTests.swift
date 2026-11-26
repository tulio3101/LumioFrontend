import Testing
import CoreGraphics
@testable import LumioFrontend

// SCRUM-33: detector de obstáculos por profundidad, independiente de la clase. Rejillas sintéticas:
// pared al frente alerta; pasillo libre no; objeto lateral (fuera del corredor) no; la fusión con
// YOLO evita doble aviso.

private let rows = 8
private let cols = 12

/// Construye una rejilla: `depthFor(r,c)` da la profundidad (<=0/.nan = inválida); `floorFor` marca piso.
private func grid(
    depthFor: (Int, Int) -> Float,
    floorFor: (Int, Int) -> Bool = { _, _ in false }
) -> CorridorDepthGrid {
    var depth = [Float](repeating: .nan, count: rows * cols)
    var floor = [Bool](repeating: false, count: rows * cols)
    for r in 0..<rows {
        for c in 0..<cols {
            depth[r * cols + c] = depthFor(r, c)
            floor[r * cols + c] = floorFor(r, c)
        }
    }
    return CorridorDepthGrid(rows: rows, cols: cols, depth: depth, floor: floor)
}

// Detector con franja central 0.3...0.7 (como el corredor por defecto 40%).
private let detector = DepthObstacleDetector(
    maxAlertDistance: 4.0, corridorXRange: 0.3...0.7, minClusterCells: 6, depthTolerance: 0.3
)

@Test func wallAheadAlertsAtItsDistance() {
    let g = grid(depthFor: { _, _ in 1.0 })   // pared uniforme a 1 m
    let hit = try! #require(detector.detect(g))
    #expect(abs(hit.distance - 1.0) < 0.001)
    #expect(hit.centerXFraction > 0.3 && hit.centerXFraction < 0.7)
}

@Test func freeCorridorDoesNotAlert() {
    // Todo es piso (descontado) → no hay obstáculo.
    let g = grid(depthFor: { _, _ in 1.5 }, floorFor: { _, _ in true })
    #expect(detector.detect(g) == nil)
}

@Test func farCorridorBeyondMaxDoesNotAlert() {
    let g = grid(depthFor: { _, _ in 6.0 })   // más lejos que maxAlertDistance
    #expect(detector.detect(g) == nil)
}

@Test func lateralObjectOutsideCorridorDoesNotAlert() {
    // Objeto cercano solo en las columnas del borde (fuera de 0.3...0.7).
    let g = grid(depthFor: { _, c in
        let x = (Float(c) + 0.5) / Float(cols)
        return (x < 0.2 || x > 0.8) ? 0.8 : 5.0
    })
    #expect(detector.detect(g) == nil)
}

@Test func singleNoisyCellDoesNotReachCluster() {
    // Una sola celda cercana entre lecturas lejanas → no supera minClusterCells.
    let g = grid(depthFor: { r, c in (r == 4 && c == 6) ? 0.9 : 5.0 })
    #expect(detector.detect(g) == nil)
}

@Test func fusionYoloBoxSuppressesGenericObstacle() {
    let hit = DepthObstacleHit(distance: 1.0, centerXFraction: 0.5)
    // Caja YOLO que cubre x=0.5 → gana YOLO, se suprime el genérico.
    let covered = CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.3)
    #expect(DepthObstacleFusion.survivingObstacle(hit, kind: .generic, yoloBoxes: [covered]) == nil)
    // Caja lejos del obstáculo → sobrevive el obstáculo de profundidad.
    let apart = CGRect(x: 0.0, y: 0.5, width: 0.1, height: 0.3)
    #expect(DepthObstacleFusion.survivingObstacle(hit, kind: .wall, yoloBoxes: [apart]) != nil)
}

@Test func meshClassMapsToSpanishName() {
    #expect(DepthObstacleKind(meshClass: .wall).spanishName == "pared")
    #expect(DepthObstacleKind(meshClass: .door).spanishName == "puerta")
    #expect(DepthObstacleKind(meshClass: .window).spanishName == "puerta")  // ventana → puerta/umbral
    #expect(DepthObstacleKind(meshClass: .seat).spanishName == "asiento")
    #expect(DepthObstacleKind(meshClass: .table).spanishName == "mesa")
    #expect(DepthObstacleKind(meshClass: .floor).spanishName == "obstáculo")  // genérico
    #expect(DepthObstacleKind(meshClass: .none).spanishName == "obstáculo")
}
