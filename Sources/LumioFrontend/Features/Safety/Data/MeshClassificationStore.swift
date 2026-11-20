#if os(iOS)
import ARKit
import simd
import os

/// Lee la clasificación de la malla LiDAR a **baja frecuencia** (2–3 Hz) y guarda la clase dominante
/// de la superficie que está **al frente** del usuario, para nombrar el obstáculo ("pared",
/// "puerta"…). Thread-safe; la consulta de malla es cara, así que se limita por tiempo y se muestrea
/// (stride) sobre las caras. Si la presión térmica obliga a apagar `sceneReconstruction`, este store
/// deja de actualizarse y el obstáculo se anuncia como genérico.
final class MeshClassificationStore {
    private struct State {
        var dominant: MeshClass = .none
        var lastUpdate: TimeInterval = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Intervalo mínimo entre lecturas (2.5 Hz ≈ 0.4 s).
    let minInterval: TimeInterval
    /// Distancia máxima (m) para considerar una superficie "al frente".
    let maxDistance: Float
    /// Se muestrea 1 de cada `faceStride` caras por ancla para acotar el costo.
    let faceStride: Int

    init(minInterval: TimeInterval = 0.4, maxDistance: Float = 3.0, faceStride: Int = 25) {
        self.minInterval = minInterval
        self.maxDistance = maxDistance
        self.faceStride = faceStride
    }

    var dominantClass: MeshClass { state.withLock { $0.dominant } }

    func reset() { state.withLock { $0 = State() } }

    /// Actualiza la clase dominante si venció el intervalo. Toma la clasificación de la cara más
    /// cercana en el cono frontal de la cámara.
    func update(meshAnchors: [ARMeshAnchor], camera: ARCamera, now: TimeInterval) {
        let due = state.withLock { now - $0.lastUpdate >= minInterval }
        guard due else { return }

        let camPos = simd_make_float3(camera.transform.columns.3)
        // Eje -Z de la cámara en mundo = hacia dónde mira.
        let forward = simd_normalize(-simd_make_float3(camera.transform.columns.2))

        var bestDist = maxDistance
        var bestClass: MeshClass = .none

        for anchor in meshAnchors {
            let geo = anchor.geometry
            guard let classification = geo.classification else { continue }
            let faceCount = geo.faces.count
            let vertices = geo.vertices
            var i = 0
            while i < faceCount {
                let cls = classification.classification(at: i)
                if cls != .none, let centroid = geo.faceCentroid(at: i, vertices: vertices) {
                    let world = simd_make_float3(anchor.transform * simd_make_float4(centroid, 1))
                    let toFace = world - camPos
                    let dist = simd_length(toFace)
                    // ¿La cara está delante (ángulo < ~45°) y más cerca que la mejor hasta ahora?
                    if dist > 0.1, dist < bestDist,
                       simd_dot(simd_normalize(toFace), forward) > 0.7 {
                        bestDist = dist
                        bestClass = MeshClass(classification: cls)
                    }
                }
                i += faceStride
            }
        }

        state.withLock {
            $0.lastUpdate = now
            $0.dominant = bestClass
        }
    }
}

// MARK: - ARKit interop helpers

private extension MeshClass {
    init(classification: ARMeshClassification) {
        switch classification {
        case .wall:    self = .wall
        case .floor:   self = .floor
        case .ceiling: self = .ceiling
        case .table:   self = .table
        case .seat:    self = .seat
        case .window:  self = .window
        case .door:    self = .door
        case .none:    self = .none
        @unknown default: self = .other
        }
    }
}

private extension ARMeshGeometry {
    func faceCentroid(at index: Int, vertices: ARGeometrySource) -> simd_float3? {
        guard index >= 0, index < faces.count else { return nil }
        let indicesPerFace = faces.indexCountPerPrimitive
        guard indicesPerFace == 3 else { return nil }
        let idxPtr = faces.buffer.contents()
        let stride = MemoryLayout<UInt32>.size
        var sum = simd_float3(repeating: 0)
        for k in 0..<3 {
            let vi = idxPtr.advanced(by: (index * indicesPerFace + k) * stride)
                .assumingMemoryBound(to: UInt32.self).pointee
            sum += vertex(at: Int(vi), source: vertices)
        }
        return sum / 3
    }

    private func vertex(at index: Int, source: ARGeometrySource) -> simd_float3 {
        let ptr = source.buffer.contents()
            .advanced(by: source.offset + source.stride * index)
            .assumingMemoryBound(to: simd_float3.self)
        return ptr.pointee
    }
}

private extension ARGeometrySource {
    /// Clasificación por primitiva (una por cara), buffer de `UInt8`.
    func classification(at index: Int) -> ARMeshClassification {
        let ptr = buffer.contents().advanced(by: offset + stride * index)
            .assumingMemoryBound(to: UInt8.self)
        return ARMeshClassification(rawValue: Int(ptr.pointee)) ?? .none
    }
}
#endif
