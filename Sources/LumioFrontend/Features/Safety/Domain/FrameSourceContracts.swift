#if os(iOS)
import ARKit
import CoreVideo

/// Clasificación de malla LiDAR cerca del frente del usuario, extraída a bajas Hz. Ligera (sin
/// geometría de la malla) para no retener el ARFrame. nil cuando no hay malla disponible/reciente.
struct MeshClassificationSnapshot {
    /// Clasificación dominante de la superficie frente al usuario en el corredor.
    let dominantClass: MeshClass
}

/// Single camera frame: always has a pixel buffer; depth fields are non-nil only on LiDAR hardware.
struct CapturedFrame {
    let pixelBuffer: CVPixelBuffer
    let depthData: ARDepthData?
    let camera: ARCamera?
    let timestamp: TimeInterval
    /// ARKit's estimated ambient intensity (lux). Read as a plain Float in the delegate so the
    /// low-light check never retains the ARFrame. nil when ARKit has no light estimate yet.
    let ambientIntensity: Float?
    /// SCRUM-33: clasificación de malla a bajas Hz (nombre fino del obstáculo). nil sin LiDAR/malla.
    let meshClassification: MeshClassificationSnapshot?
    /// SCRUM-33: altura (world Y, metros) del plano de piso estimado, para descontar el suelo.
    /// nil si aún no se estima (sin plano horizontal ni profundidad).
    let floorHeight: Float?

    init(
        pixelBuffer: CVPixelBuffer,
        depthData: ARDepthData?,
        camera: ARCamera?,
        timestamp: TimeInterval,
        ambientIntensity: Float? = nil,
        meshClassification: MeshClassificationSnapshot? = nil,
        floorHeight: Float? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.depthData = depthData
        self.camera = camera
        self.timestamp = timestamp
        self.ambientIntensity = ambientIntensity
        self.meshClassification = meshClassification
        self.floorHeight = floorHeight
    }
}

/// Abstraction over camera input (ARKit today, AVCapture dual in SCRUM-349).
/// "Latest frame wins": if the consumer is behind, intermediate frames are dropped.
protocol FrameSource: AnyObject {
    var isDepthAvailable: Bool { get }
    var frames: AsyncStream<CapturedFrame> { get }
    func start() throws
    func stop()
    /// Called by the consumer (DetectionPipeline) when it finishes processing a frame,
    /// allowing the source to accept the next one. Part of the single-frame gate pattern
    /// that prevents ARFrame accumulation (ARKit warns when >3 frames are retained).
    func frameProcessingComplete()
}
#endif
