#if os(iOS)
import ARKit
import CoreVideo

/// Single camera frame: always has a pixel buffer; depth fields are non-nil only on LiDAR hardware.
struct CapturedFrame {
    let pixelBuffer: CVPixelBuffer
    let depthData: ARDepthData?
    let camera: ARCamera?
    let timestamp: TimeInterval
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
