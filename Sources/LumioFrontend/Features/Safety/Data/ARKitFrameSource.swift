#if os(iOS)
import ARKit

/// ARKit-based FrameSource. On LiDAR devices activates sceneDepth automatically.
/// SCRUM-223: re-runs the session automatically after system interruptions (phone calls, etc.).
final class ARKitFrameSource: NSObject, FrameSource {
    private let session = ARSession()
    private(set) var isDepthAvailable = false
    private var activeConfig: ARWorldTrackingConfiguration?

    let frames: AsyncStream<CapturedFrame>
    private let continuation: AsyncStream<CapturedFrame>.Continuation

    override init() {
        var cont: AsyncStream<CapturedFrame>.Continuation!
        frames = AsyncStream<CapturedFrame>(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        continuation = cont
        super.init()
        session.delegate = self
    }

    func start() throws {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = .sceneDepth
            isDepthAvailable = true
        }
        activeConfig = config
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        activeConfig = nil
        session.pause()
        continuation.finish()
    }
}

extension ARKitFrameSource: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        continuation.yield(CapturedFrame(
            pixelBuffer: frame.capturedImage,
            depthData: frame.sceneDepth,
            camera: frame.camera,
            timestamp: frame.timestamp
        ))
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) { }

    /// SCRUM-223: resume frame delivery after a system interruption ends.
    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        guard let config = activeConfig else { return }
        session.run(config, options: [.resetTracking])
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        continuation.finish()
    }
}
#endif
