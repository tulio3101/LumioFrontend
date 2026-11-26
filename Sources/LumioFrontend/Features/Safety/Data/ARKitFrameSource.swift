#if os(iOS)
import ARKit
import AVFoundation
import OSLog
import os  // OSAllocatedUnfairLock (iOS 16+)
import simd

/// ARKit-based FrameSource. On LiDAR devices activates sceneDepth and (bajo presión térmica
/// moderada) la reconstrucción de malla clasificada; sin LiDAR usa detección de planos verticales.
/// SCRUM-223: re-runs the session automatically after system interruptions (phone calls, etc.).
final class ARKitFrameSource: NSObject, FrameSource {
    private let session = ARSession()
    /// SCRUM-321: el delegado de ARSession corre en una cola PROPIA (no en main), para que la
    /// lectura de malla, la desproyección y el muestreo no bloqueen el hilo principal ("UI
    /// unresponsiveness on the main thread").
    private let delegateQueue = DispatchQueue(label: "com.lumio.arsession", qos: .userInitiated)
    private(set) var isDepthAvailable = false
    private var activeConfig: ARWorldTrackingConfiguration?

    /// SCRUM-37: el flujo se reemplaza en cada `start()` (un flujo terminado no se reutiliza).
    /// Se protege con un lock porque el delegado de ARSession produce desde su propia cola.
    private struct FrameStream {
        var stream: AsyncStream<CapturedFrame>
        var continuation: AsyncStream<CapturedFrame>.Continuation
    }
    private let frameStream: OSAllocatedUnfairLock<FrameStream>
    var frames: AsyncStream<CapturedFrame> { frameStream.withLockUnchecked { $0.stream } }

    /// Single-frame gate: true while the pipeline is processing a frame.
    /// Checked synchronously in the ARSession delegate before any memory is allocated.
    /// This guarantees at most one CVPixelBuffer (and hence one ARFrame) is retained at a time.
    private let processingGate = OSAllocatedUnfairLock(initialState: false)

    /// Malla + piso recolectados de los anchors (para nombrar obstáculos y descontar el suelo).
    private let meshStore = MeshClassificationStore()
    private struct AnchorState {
        /// Plano horizontal candidato a piso: centro en mundo y "radio" (media extensión mayor).
        struct FloorPlane { var center: simd_float3; var radius: Float }
        var meshAnchors: [UUID: ARMeshAnchor] = [:]
        var floorPlanes: [UUID: FloorPlane] = [:]
        var meshEnabled = false
    }
    private let anchorState = OSAllocatedUnfairLock(initialState: AnchorState())

    /// SCRUM-38: pedidos de foto para la narración, atendidos con el siguiente frame con
    /// seguimiento normal. Independientes de `processingGate`: no consumen ni retrasan los
    /// frames del loop de seguridad.
    private let narrationRequests = OSAllocatedUnfairLock(
        uncheckedState: [UUID: CheckedContinuation<NarrationCapture, Never>]()
    )
    private let narrationEncoder = NarrationFrameEncoder()
    /// Si en este tiempo no llega un frame útil (cámara tapada o movida), se informa.
    static let narrationCaptureTimeout: TimeInterval = 1.5

    private let logger = Logger(subsystem: "com.lumio.app", category: "ARKitFrameSource")
    /// El piso es el plano horizontal **bajo los pies**: su extensión contiene la posición xz de la
    /// cámara y está entre estos metros por debajo de ella (SCRUM-33). Así una mesa (muy cerca) o un
    /// nivel inferior lejano no se confunden con el suelo.
    static let floorUnderFeetMin: Float = 0.9
    static let floorUnderFeetMax: Float = 1.8
    /// Holgura (m) para el test de "la cámara está sobre el plano" (ignora la rotación del plano).
    static let floorContainmentSlack: Float = 0.3
    #if DEBUG
    private static var lastFrameLogTime: Double = 0
    #endif

    override init() {
        let initial = makeSafetyStream(of: CapturedFrame.self, bufferingPolicy: .bufferingNewest(1))
        frameStream = OSAllocatedUnfairLock(
            uncheckedState: FrameStream(stream: initial.stream, continuation: initial.continuation)
        )
        super.init()
        session.delegate = self
        session.delegateQueue = delegateQueue   // SCRUM-321: trabajo pesado fuera del main thread
        NotificationCenter.default.addObserver(
            self, selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func start() throws {
        // SCRUM-37: sin hardware compatible o con cámara denegada/restringida no se abre la
        // sesión; el pipeline lo publica como captura no disponible. Si aún no se pidió el
        // permiso, ARKit muestra la solicitud del sistema (la compuerta SCRUM-315 la prepara).
        guard ARWorldTrackingConfiguration.isSupported else { throw FrameSourceError.unsupported }
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        guard authorization != .denied, authorization != .restricted else {
            throw FrameSourceError.cameraPermissionRequired
        }
        // Flujo nuevo por sesión: stop() o un fallo terminaron el anterior.
        let next = makeSafetyStream(of: CapturedFrame.self, bufferingPolicy: .bufferingNewest(1))
        let previous = frameStream.withLockUnchecked { state -> AsyncStream<CapturedFrame>.Continuation in
            let old = state.continuation
            state = FrameStream(stream: next.stream, continuation: next.continuation)
            return old
        }
        previous.finish()
        processingGate.withLock { $0 = false }
        let config = makeConfig()
        activeConfig = config
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        activeConfig = nil
        resolveNarrationRequests(with: .cameraInactive)
        session.pause()
        meshStore.reset()
        anchorState.withLock { $0 = AnchorState() }
        frameStream.withLockUnchecked { $0.continuation }.finish()
    }

    func frameProcessingComplete() {
        processingGate.withLock { $0 = false }
    }

    /// Construye la configuración según hardware y presión térmica. La malla clasificada se
    /// **desactiva** cuando el `thermalState` es `.serious`/`.critical` (la profundidad sigue).
    private func makeConfig() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        isDepthAvailable = false
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

// MARK: SCRUM-38 · Foto para la narración

extension ARKitFrameSource: NarrationFrameCapturing {
    func captureNarrationFrame() async -> NarrationCapture {
        guard activeConfig != nil else { return .cameraInactive }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            narrationRequests.withLockUnchecked { $0[id] = continuation }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + Self.narrationCaptureTimeout
            ) { [weak self] in
                self?.resolveNarrationRequest(id, with: .noUsableFrame)
            }
        }
    }

    private nonisolated func resolveNarrationRequest(_ id: UUID, with capture: NarrationCapture) {
        narrationRequests.withLockUnchecked { $0.removeValue(forKey: id) }?.resume(returning: capture)
    }

    private nonisolated func resolveNarrationRequests(with capture: NarrationCapture) {
        let pending = narrationRequests.withLockUnchecked { requests in
            defer { requests.removeAll() }
            return Array(requests.values)
        }
        for continuation in pending { continuation.resume(returning: capture) }
    }

    /// Solo trabaja si alguien pidió una foto y el frame sirve (seguimiento normal: la cámara
    /// no está tapada ni movida). Reduce la imagen aquí para no retener el `ARFrame` y
    /// codifica el JPEG fuera de la cola del delegado.
    private nonisolated func serveNarrationRequests(from frame: ARFrame) {
        let hasRequests = narrationRequests.withLockUnchecked { !$0.isEmpty }
        guard hasRequests, case .normal = frame.camera.trackingState else { return }
        let capturedAt = Date()
        guard let image = narrationEncoder.downscaledImage(from: frame.capturedImage) else { return }
        let pending = narrationRequests.withLockUnchecked { requests in
            defer { requests.removeAll() }
            return Array(requests.values)
        }
        guard !pending.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let capture: NarrationCapture = NarrationFrameEncoder.jpeg(from: image)
                .map { .frame(NarrationFrame(jpeg: $0, capturedAt: capturedAt)) } ?? .noUsableFrame
            for continuation in pending { continuation.resume(returning: capture) }
        }
    }
}

extension ARKitFrameSource: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // SCRUM-38: antes de la compuerta del detector, para que una foto pedida no espere a
        // que termine la inferencia. No toca `processingGate`.
        serveNarrationRequests(from: frame)
        // Synchronous gate check BEFORE creating any objects or copying the pixelBuffer.
        // If the detector is still processing the previous frame, drop this one immediately
        // so ARKit can reclaim it — preventing the "retaining N ARFrames" accumulation.
        let acquired = processingGate.withLock { (busy: inout Bool) -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard acquired else { return }
        // SCRUM-37: tras stop() o un fallo pueden llegar frames rezagados; no se entregan.
        guard activeConfig != nil else {
            frameProcessingComplete()
            return
        }

        #if DEBUG
        let ts = frame.timestamp
        if ts - ARKitFrameSource.lastFrameLogTime > 1.0 {
            ARKitFrameSource.lastFrameLogTime = ts
            logger.debug("frame recibido ts=\(ts, format: .fixed(precision: 1)) depth=\(frame.sceneDepth != nil)")
        }
        #endif

        // Read the light estimate as a Float here, before yielding — avoids retaining the ARFrame.
        let ambientIntensity = frame.lightEstimate.map { Float($0.ambientIntensity) }

        // SCRUM-33 (desniveles): el piso es el plano horizontal BAJO LOS PIES (su extensión contiene
        // la xz de la cámara, 0.9–1.8 m debajo). Se recalcula por frame → se actualiza al moverse.
        // Si no hay ninguno confiable, `floorHeight = nil` y el pipeline no analiza desniveles.
        let camPos = simd_make_float3(frame.camera.transform.columns.3)
        let camXZ = simd_float2(camPos.x, camPos.z)
        // Malla clasificada a baja frecuencia (la propia store limita a ~2.5 Hz).
        let snapshot = anchorState.withLock { state -> ([ARMeshAnchor], Float?) in
            let floor = state.floorPlanes.values.filter { fp in
                let below = camPos.y - fp.center.y
                guard below >= ARKitFrameSource.floorUnderFeetMin,
                      below <= ARKitFrameSource.floorUnderFeetMax else { return false }
                let d = simd_distance(camXZ, simd_float2(fp.center.x, fp.center.z))
                return d <= fp.radius + ARKitFrameSource.floorContainmentSlack
            }
            // El más alto entre los válidos = el suelo inmediato bajo los pies.
            let floorY = floor.max(by: { $0.center.y < $1.center.y })?.center.y
            return (Array(state.meshAnchors.values), floorY)
        }
        meshStore.update(meshAnchors: snapshot.0, camera: frame.camera, now: frame.timestamp)
        let dominant = meshStore.dominantClass
        let meshClassification = dominant == .none ? nil : MeshClassificationSnapshot(dominantClass: dominant)

        frameStream.withLockUnchecked { $0.continuation }.yield(CapturedFrame(
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
                state.floorPlanes.removeValue(forKey: anchor.identifier)
            }
        }
    }

    private nonisolated func ingest(_ anchors: [ARAnchor]) {
        anchorState.withLock { state in
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    state.meshAnchors[mesh.identifier] = mesh
                } else if let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal {
                    // Centro en mundo + "radio" (media extensión mayor). La selección del piso bajo
                    // los pies se hace por frame en session(_:didUpdate:).
                    let worldCenter = simd_make_float3(plane.transform * simd_float4(plane.center, 1))
                    let radius = max(plane.planeExtent.width, plane.planeExtent.height) / 2
                    state.floorPlanes[plane.identifier] = AnchorState.FloorPlane(
                        center: worldCenter, radius: radius
                    )
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
        // SCRUM-37: el fin inesperado de la captura termina el flujo; el pipeline lo publica
        // como captura no disponible y se puede reintentar (Reintentar detección).
        activeConfig = nil
        resolveNarrationRequests(with: .cameraInactive)
        session.pause()
        frameStream.withLockUnchecked { $0.continuation }.finish()
    }
}
#endif
