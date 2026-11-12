#if os(iOS)
import ARKit
import OSLog
import os  // OSAllocatedUnfairLock (iOS 16+)

/// ARKit-based FrameSource. On LiDAR devices activates sceneDepth automatically.
/// SCRUM-223: re-runs the session automatically after system interruptions (phone calls, etc.).
final class ARKitFrameSource: NSObject, FrameSource {
    private let session = ARSession()
    private(set) var isDepthAvailable = false
    private var activeConfig: ARWorldTrackingConfiguration?

    let frames: AsyncStream<CapturedFrame>
    private let continuation: AsyncStream<CapturedFrame>.Continuation

    /// Single-frame gate: true while the pipeline is processing a frame.
    /// Checked synchronously in the ARSession delegate before any memory is allocated.
    /// This guarantees at most one CVPixelBuffer (and hence one ARFrame) is retained at a time.
    private let processingGate = OSAllocatedUnfairLock(initialState: false)

    private let logger = Logger(subsystem: "com.lumio.app", category: "ARKitFrameSource")
    #if DEBUG
    private static var lastFrameLogTime: Double = 0
    #endif

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

    func frameProcessingComplete() {
        processingGate.withLock { $0 = false }
    }

    #if DEBUG
    var arSession: ARSession { session }
    #endif
}

extension ARKitFrameSource: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Synchronous gate check BEFORE creating any objects or copying the pixelBuffer.
        // If the detector is still processing the previous frame, drop this one immediately
        // so ARKit can reclaim it — preventing the "retaining N ARFrames" accumulation.
        let acquired = processingGate.withLock { (busy: inout Bool) -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard acquired else { return }

        #if DEBUG
        let ts = frame.timestamp
        if ts - ARKitFrameSource.lastFrameLogTime > 1.0 {
            ARKitFrameSource.lastFrameLogTime = ts
            logger.debug("frame recibido ts=\(ts, format: .fixed(precision: 1)) depth=\(frame.sceneDepth != nil)")
        }
        #endif

        // Read the light estimate as a Float here, before yielding — avoids retaining the ARFrame.
        let ambientIntensity = frame.lightEstimate.map { Float($0.ambientIntensity) }

        continuation.yield(CapturedFrame(
            pixelBuffer: frame.capturedImage,
            depthData: frame.sceneDepth,
            camera: frame.camera,
            timestamp: frame.timestamp,
            ambientIntensity: ambientIntensity
        ))
        // ARFrame is released here; CapturedFrame holds extracted data only.
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        logger.info("ARSession interrumpida")
    }

    /// SCRUM-223: resume frame delivery after a system interruption ends.
    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        logger.info("ARSession reanudada — reiniciando configuración")
        guard let config = activeConfig else { return }
        session.run(config, options: [.resetTracking])
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        logger.error("ARSession falló: \(error)")
        continuation.finish()
    }
}
#endif
