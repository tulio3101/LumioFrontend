#if os(iOS)
import ARKit
import CoreGraphics

/// Estimates distance to an obstacle using ARKit LiDAR sceneDepth data.
/// Per ADR-307: samples the median depth of the 30% central area of the bounding box,
/// using only high-confidence pixels. Returns nil for distances > 4 m or no valid pixels.
struct DepthSampler {
    static let maxAlertDistanceMeters: Float = 4.0

    /// - Parameter normalizedBox: top-left origin bounding box (as in Detection.boundingBox).
    static func sampleDepth(
        at normalizedBox: CGRect,
        depthData: ARDepthData
    ) -> Float? {
        let depthMap = depthData.depthMap
        guard let confidenceMap = depthData.confidenceMap else { return nil }

        let width  = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        // Shrink to 30% central area: inset each side by 35% of the box dimension.
        let inner = normalizedBox.insetBy(
            dx: normalizedBox.width  * 0.35,
            dy: normalizedBox.height * 0.35
        )
        let x0 = max(0, Int(inner.minX * CGFloat(width)))
        let x1 = min(width,  Int(inner.maxX * CGFloat(width)))
        let y0 = max(0, Int(inner.minY * CGFloat(height)))
        let y1 = min(height, Int(inner.maxY * CGFloat(height)))
        guard x0 < x1, y0 < y1 else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
        }

        let depthStride = CVPixelBufferGetBytesPerRow(depthMap)
        let confStride  = CVPixelBufferGetBytesPerRow(confidenceMap)
        let depthBase   = CVPixelBufferGetBaseAddress(depthMap)!
        let confBase    = CVPixelBufferGetBaseAddress(confidenceMap)!

        var samples: [Float] = []
        for y in y0..<y1 {
            let depthRow = depthBase.advanced(by: y * depthStride)
                                    .assumingMemoryBound(to: Float.self)
            let confRow  = confBase.advanced(by: y * confStride)
                                   .assumingMemoryBound(to: UInt8.self)
            for x in x0..<x1 {
                guard ARConfidenceLevel(rawValue: confRow[x]) == .high else { continue }
                let d = depthRow[x]
                guard d > 0, d.isFinite else { continue }
                samples.append(d)
            }
        }

        guard !samples.isEmpty else { return nil }
        samples.sort()
        let median = samples[samples.count / 2]
        return median <= maxAlertDistanceMeters ? median : nil
    }
}
#endif
