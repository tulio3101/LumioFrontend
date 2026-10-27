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
}
#endif
