#if os(iOS)
import Foundation

/// Lo que SafetyService necesita del pipeline de detección. Abstraerlo permite inyectar un
/// doble en pruebas sin ARKit ni Core ML (DetectionPipeline es el único implementador real).
protocol ObstacleDetectionPipeline: AnyObject {
    var detections: AsyncStream<SafetyFrameOutput> { get }
    /// true en dispositivos con LiDAR; decide si los avisos de distancia son exactos.
    var isDepthAvailable: Bool { get }
    func start() throws
    func stop()
    #if DEBUG
    /// Fuente ARKit para el preview de depuración; nil con cualquier otra fuente.
    var previewFrameSource: ARKitFrameSource? { get }
    #endif
}
#endif
