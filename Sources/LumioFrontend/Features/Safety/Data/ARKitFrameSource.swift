#if os(iOS)
import ARKit
import OSLog
import os  // OSAllocatedUnfairLock (iOS 16+)
import simd

/// ARKit-based FrameSource. On LiDAR devices activates sceneDepth and (bajo presión térmica
/// moderada) la reconstrucción de malla clasificada; sin LiDAR usa detección de planos verticales.
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

    /// Malla + piso recolectados de los anchors (para nombrar obstáculos y descontar el suelo).
    private let meshStore = MeshClassificationStore()
    private struct AnchorState {
        var meshAnchors: [UUID: ARMeshAnchor] = [:]
        var floorHeights: [UUID: Float] = [:]
        var meshEnabled = false
    }
    private let anchorState = OSAllocatedUnfairLock(initialState: AnchorState())

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func start() throws {
        let config = makeConfig()
        activeConfig = config
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        activeConfig = nil
        session.pause()
        meshStore.reset()
        anchorState.withLock { $0 = AnchorState() }
        continuation.finish()
    }

    func frameProcessingComplete() {
        processingGate.withLock { $0 = false }
    }

    /// Construye la configuración según hardware y presión térmica. La malla clasificada se
    /// **desactiva** cuando el `thermalState` es `.serious`/`.critical` (la profundidad sigue).
    private func makeConfig() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = .sceneDepth
            isDepthAvailable = true
        }
        // Planos para estimar el piso (horizontal) y, sin LiDAR, obstáculos (vertical).
        config.planeDetection = [.horizontal, .vertical]
        var meshEnabled = false
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal != .serious, thermal != .critical {
                config.sceneReconstruction = .meshWithClassification
                meshEnabled = true
            }
        }
        anchorState.withLock { $0.meshEnabled = meshEnabled }
        return config
    }

    @objc private func thermalStateChanged() {
        guard activeConfig != nil else { return }
        let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        let thermal = ProcessInfo.processInfo.thermalState
        let shouldMesh = supportsMesh && thermal != .serious && thermal != .critical
        let was = anchorState.withLock { $0.meshEnabled }
        guard shouldMesh != was else { return }
        logger.info("thermalState=\(thermal.rawValue) → malla \(shouldMesh ? "ON" : "OFF")")
        let config = makeConfig()            // recalcula meshEnabled
        activeConfig = config
        session.run(config, options: [])     // conserva tracking y anchors
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

        // Malla clasificada a baja frecuencia (la propia store limita a ~2.5 Hz).
        let snapshot = anchorState.withLock { (Array($0.meshAnchors.values), $0.floorHeights.values.min()) }
        meshStore.update(meshAnchors: snapshot.0, camera: frame.camera, now: frame.timestamp)
        let dominant = meshStore.dominantClass
        let meshClassification = dominant == .none ? nil : MeshClassificationSnapshot(dominantClass: dominant)

        continuation.yield(CapturedFrame(
            pixelBuffer: frame.capturedImage,
            depthData: frame.sceneDepth,
            camera: frame.camera,
            timestamp: frame.timestamp,
            ambientIntensity: ambientIntensity,
            meshClassification: meshClassification,
            floorHeight: snapshot.1
        ))
        // ARFrame is released here; CapturedFrame holds extracted data only.
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { ingest(anchors) }
    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { ingest(anchors) }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        anchorState.withLock { state in
            for anchor in anchors {
                state.meshAnchors.removeValue(forKey: anchor.identifier)
                state.floorHeights.removeValue(forKey: anchor.identifier)
            }
        }
    }

    private nonisolated func ingest(_ anchors: [ARAnchor]) {
        anchorState.withLock { state in
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    state.meshAnchors[mesh.identifier] = mesh
                } else if let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal {
                    // Altura (world Y) del centro del plano horizontal; el piso es el más bajo.
                    let center = plane.transform * simd_float4(plane.center, 1)
                    state.floorHeights[plane.identifier] = center.y
                }
            }
        }
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
