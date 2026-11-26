#if os(iOS)
import ARKit
import CoreGraphics
import simd

/// Construye el `ElevationProfile` (valor puro) desde `ARDepthData` + `ARCamera` + `floorHeight`:
/// desproyecta las celdas del corredor a mundo, calcula la distancia hacia adelante y la altura
/// respecto al plano de piso, y las agrupa en bins de distancia. Mismo patrón de desproyección que
/// `CorridorDepthSampler`.
///
/// AJUSTE: una mediana por debajo del piso NO se vuelve hueco — se conserva la altura negativa
/// medida (para ver bajadas escalonadas). `nil` (hueco) solo cuando el bin no tiene muestras `.high`.
enum ElevationProfileSampler {
    static func profile(
        from depth: ARDepthData,
        corridor: CGRect,
        camera: ARCamera,
        floorHeight: Float,
        nearMeters: Float,
        farMeters: Float,
        ceilingMeters: Float,
        binWidth: Float = 0.25
    ) -> ElevationProfile? {
        guard farMeters > nearMeters, binWidth > 0 else { return nil }
        let depthMap = depth.depthMap
        guard let confidenceMap = depth.confidenceMap else { return nil }

        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        let x0 = max(0, Int(corridor.minX * CGFloat(w)))
        let x1 = min(w, Int(corridor.maxX * CGFloat(w)))
        let y0 = max(0, Int(corridor.minY * CGFloat(h)))
        let y1 = min(h, Int(corridor.maxY * CGFloat(h)))
        guard x0 < x1, y0 < y1 else { return nil }

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

        let imgRes = camera.imageResolution
        let k = camera.intrinsics
        let sx = Float(w) / Float(imgRes.width)
        let sy = Float(h) / Float(imgRes.height)
        let fx = k[0][0] * sx, fy = k[1][1] * sy
        let cx = k[2][0] * sx, cy = k[2][1] * sy
        let transform = camera.transform

        let camPos = simd_make_float3(transform.columns.3)
        var forward = -simd_make_float3(transform.columns.2)   // -Z de la cámara
        forward.y = 0
        forward = simd_length(forward) > 1e-4 ? simd_normalize(forward) : simd_float3(0, 0, -1)

        let binCount = max(1, Int((farMeters - nearMeters) / binWidth))
        var bins = [[Float]](repeating: [], count: binCount)

        for v in y0..<y1 {
            let depthRow = depthBase.advanced(by: v * depthStride).assumingMemoryBound(to: Float.self)
            let confRow = confBase.advanced(by: v * confStride).assumingMemoryBound(to: UInt8.self)
            for u in x0..<x1 {
                guard ARConfidenceLevel(rawValue: Int(confRow[u])) == .high else { continue }
                let d = depthRow[u]
                guard d > 0, d.isFinite else { continue }
                let xC = (Float(u) - cx) / fx * d
                let yC = -(Float(v) - cy) / fy * d
                let zC = -d
                let world = simd_make_float3(transform * simd_float4(xC, yC, zC, 1))
                let fwd = simd_dot(world - camPos, forward)   // distancia adelante (m)
                guard fwd >= nearMeters, fwd < farMeters else { continue }
                let height = world.y - floorHeight
                // Franja de piso: se descartan los puntos muy por encima del suelo (paredes,
                // zócalos altos, mobiliario). Las bajadas (altura negativa) se conservan.
                guard height <= ceilingMeters else { continue }
                let idx = min(binCount - 1, Int((fwd - nearMeters) / binWidth))
                bins[idx].append(height)
            }
        }

        let samples = (0..<binCount).map { i -> ElevationSample in
            let forwardMeters = nearMeters + (Float(i) + 0.5) * binWidth
            var heights = bins[i]
            guard !heights.isEmpty else {
                return ElevationSample(forwardMeters: forwardMeters, heightAboveFloor: nil)
            }
            heights.sort()
            return ElevationSample(forwardMeters: forwardMeters, heightAboveFloor: heights[heights.count / 2])
        }
        return ElevationProfile(samples: samples)
    }
}
#endif
