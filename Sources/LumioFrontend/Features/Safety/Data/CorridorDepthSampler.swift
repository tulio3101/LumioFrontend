#if os(iOS)
import ARKit
import CoreGraphics
import simd

/// Convierte `ARDepthData` en la `CorridorDepthGrid` (valor puro) que consume
/// `DepthObstacleDetector`. Submuestrea la franja del corredor en una rejilla pequeña: por celda
/// toma la mediana de la profundidad de alta confianza y marca si es piso (descontando el suelo con
/// el plano estimado). Mantiene la misma convención de coordenadas normalizadas que `DepthSampler`.
///
/// NOTA: la desproyección usa `camera.intrinsics` escaladas a la resolución del mapa de profundidad;
/// el descuento de piso depende de `floorHeight`. Ajustar/validar en device (orientación del buffer).
enum CorridorDepthSampler {
    static func grid(
        from depth: ARDepthData,
        corridor: CGRect,
        camera: ARCamera,
        floorHeight: Float?,
        floorBand: Float,
        rows: Int = 8,
        cols: Int = 12
    ) -> CorridorDepthGrid? {
        let depthMap = depth.depthMap
        guard let confidenceMap = depth.confidenceMap else { return nil }

        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        let x0 = max(0, Int(corridor.minX * CGFloat(w)))
        let x1 = min(w, Int(corridor.maxX * CGFloat(w)))
        let y0 = max(0, Int(corridor.minY * CGFloat(h)))
        let y1 = min(h, Int(corridor.maxY * CGFloat(h)))
        guard x0 < x1, y0 < y1, rows > 0, cols > 0 else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
        }
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap)
        let confStride = CVPixelBufferGetBytesPerRow(confidenceMap)
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confBase = CVPixelBufferGetBaseAddress(confidenceMap) else { return nil }

        // Intrínsecos escalados a la resolución de profundidad (para desproyectar y descontar piso).
        let imgRes = camera.imageResolution
        let k = camera.intrinsics
        let sx = Float(w) / Float(imgRes.width)
        let sy = Float(h) / Float(imgRes.height)
        let fx = k[0][0] * sx, fy = k[1][1] * sy
        let cx = k[2][0] * sx, cy = k[2][1] * sy
        let transform = camera.transform

        var depthCells = [Float](repeating: .nan, count: rows * cols)
        var floorCells = [Bool](repeating: false, count: rows * cols)

        let cellW = max(1, (x1 - x0) / cols)
        let cellH = max(1, (y1 - y0) / rows)

        for r in 0..<rows {
            let py0 = y0 + r * cellH
            let py1 = min(y1, py0 + cellH)
            for c in 0..<cols {
                let px0 = x0 + c * cellW
                let px1 = min(x1, px0 + cellW)
                var samples: [Float] = []
                var floorVotes = 0
                for v in py0..<py1 {
                    let depthRow = depthBase.advanced(by: v * depthStride)
                        .assumingMemoryBound(to: Float.self)
                    let confRow = confBase.advanced(by: v * confStride)
                        .assumingMemoryBound(to: UInt8.self)
                    for u in px0..<px1 {
                        guard ARConfidenceLevel(rawValue: Int(confRow[u])) == .high else { continue }
                        let d = depthRow[u]
                        guard d > 0, d.isFinite else { continue }
                        samples.append(d)
                        if let floorHeight,
                           isFloor(u: u, v: v, d: d, fx: fx, fy: fy, cx: cx, cy: cy,
                                   transform: transform, floorHeight: floorHeight, band: floorBand) {
                            floorVotes += 1
                        }
                    }
                }
                guard !samples.isEmpty else { continue }
                samples.sort()
                depthCells[r * cols + c] = samples[samples.count / 2]
                // Celda = piso si la mayoría de sus muestras caen en la banda del piso.
                floorCells[r * cols + c] = floorVotes * 2 >= samples.count
            }
        }

        return CorridorDepthGrid(rows: rows, cols: cols, depth: depthCells, floor: floorCells)
    }

    /// Desproyecta el píxel a mundo y decide si su altura cae en la banda del plano de piso.
    private static func isFloor(
        u: Int, v: Int, d: Float,
        fx: Float, fy: Float, cx: Float, cy: Float,
        transform: simd_float4x4, floorHeight: Float, band: Float
    ) -> Bool {
        // Cámara ARKit: +x derecha, +y arriba, -z adelante; la fila de imagen crece hacia abajo.
        let xC = (Float(u) - cx) / fx * d
        let yC = -(Float(v) - cy) / fy * d
        let zC = -d
        let world = transform * simd_float4(xC, yC, zC, 1)
        return abs(world.y - floorHeight) <= band
    }
}
#endif
