#if os(iOS)
import Foundation
import Testing
@testable import LumioFrontend

// SCRUM-33: al parar, SafetyService cancela solo su contexto de audio ("safety") en vez de
// resetear toda la sesión, para no pisar el audio de navegación.

final class FakeObstaclePipeline: ObstacleDetectionPipeline, @unchecked Sendable {
    private(set) var detections: AsyncStream<SafetyFrameOutput>
    private var continuation: AsyncStream<SafetyFrameOutput>.Continuation
    private(set) var statusUpdates: AsyncStream<SafetyStatus>
    private var statusContinuation: AsyncStream<SafetyStatus>.Continuation
    var isDepthAvailable: Bool
    /// Estados que publica cada start() (SCRUM-37). Por defecto: prepara y queda activa.
    var statesOnStart: [SafetyStatus] = [.starting, .running]
    private(set) var starts = 0
    private(set) var stops = 0

    init(isDepthAvailable: Bool = true) {
        self.isDepthAvailable = isDepthAvailable
        let output = makeSafetyStream(of: SafetyFrameOutput.self)
        detections = output.stream
        continuation = output.continuation
        let state = makeSafetyStream(of: SafetyStatus.self)
        statusUpdates = state.stream
        statusContinuation = state.continuation
    }

    func start() async {
        starts += 1
        let output = makeSafetyStream(of: SafetyFrameOutput.self)
        detections = output.stream
        continuation = output.continuation
        let state = makeSafetyStream(of: SafetyStatus.self)
        statusUpdates = state.stream
        statusContinuation = state.continuation
        for value in statesOnStart { statusContinuation.yield(value) }
    }

    func publish(_ status: SafetyStatus) { statusContinuation.yield(status) }

    func stop() {
        stops += 1
        continuation.finish()
        statusContinuation.finish()
    }
    #if DEBUG
    var previewFrameSource: ARKitFrameSource? { nil }
    #endif
}

/// Espera a que el servicio procese los estados publicados (llegan por un Task).
@MainActor
private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

@Test @MainActor func stopCancelsOnlySafetyContextNotWholeSession() async throws {
    let arbiter = SpyArbiter()
    let pipeline = FakeObstaclePipeline()
    let service = SafetyService(pipeline: pipeline, audioArbiter: arbiter)

    try await service.start()
    service.stop()

    #expect(arbiter.cancelledContexts == [Set(["safety"])])
    #expect(arbiter.resets == 0)
    #expect(pipeline.stops == 1)
    #expect(service.status == .stopped)
}

// SCRUM-320: el usuario sabe por audio si opera en modo completo (LiDAR) o reducido (sin LiDAR).
// SCRUM-37: se anuncia con la primera inferencia válida, no solo por haber cargado el modelo.

@Test @MainActor func announcesFullModeOnLidarDevice() async throws {
    let arbiter = SpyArbiter()
    let service = SafetyService(pipeline: FakeObstaclePipeline(isDepthAvailable: true), audioArbiter: arbiter)

    try await service.start()
    await eventually { service.status == .running }
    service.stop()

    #expect(arbiter.received.contains { $0.deduplicationKey == "safety-mode-full" })
    #expect(!arbiter.received.contains { $0.deduplicationKey == "safety-mode-reduced" })
}

@Test @MainActor func announcesReducedModeWithoutLidar() async throws {
    let arbiter = SpyArbiter()
    let service = SafetyService(pipeline: FakeObstaclePipeline(isDepthAvailable: false), audioArbiter: arbiter)

    try await service.start()
    await eventually { service.status == .running }
    service.stop()

    #expect(arbiter.received.contains { $0.deduplicationKey == "safety-mode-reduced" })
    #expect(!arbiter.received.contains { $0.deduplicationKey == "safety-mode-full" })
}

@Test @MainActor func modeIsNotAnnouncedWhenModelNeverRuns() async throws {
    let arbiter = SpyArbiter()
    let pipeline = FakeObstaclePipeline()
    pipeline.statesOnStart = [.starting, .unavailable(.model(.modelNotFound))]
    let service = SafetyService(pipeline: pipeline, audioArbiter: arbiter)

    try await service.start()
    await eventually { service.status == .unavailable(.model(.modelNotFound)) }

    #expect(!arbiter.received.contains { $0.deduplicationKey == "safety-mode-full" })
    #expect(arbiter.received.filter { $0.deduplicationKey == "safety-unavailable" }.count == 1)
    service.stop()
}

// SCRUM-37: un episodio de fallo genera UN aviso P1 aunque haya varios intentos; la
// recuperación confirmada genera un aviso P2.

@Test @MainActor func outageIsAnnouncedOnceAndRecoveryOnce() async throws {
    let arbiter = SpyArbiter()
    let pipeline = FakeObstaclePipeline()
    let service = SafetyService(pipeline: pipeline, audioArbiter: arbiter)

    try await service.start()
    await eventually { service.status == .running }
    pipeline.publish(.recovering(attempt: 1))
    pipeline.publish(.recovering(attempt: 2))
    pipeline.publish(.running)
    await eventually { arbiter.received.contains { $0.deduplicationKey == "safety-recovered" } }

    let outages = arbiter.received.filter { $0.deduplicationKey == "safety-unavailable" }
    #expect(outages.count == 1)
    #expect(outages.first?.priority == .immediateRisk)
    let recovered = arbiter.received.filter { $0.deduplicationKey == "safety-recovered" }
    #expect(recovered.count == 1)
    #expect(recovered.first?.priority == .routeInformation)
    #expect(recovered.first?.expiresAt != nil)
    service.stop()
}

@Test @MainActor func retryStartsFreshSessionOnlyWhileDetectionIsRequested() async throws {
    let arbiter = SpyArbiter()
    let pipeline = FakeObstaclePipeline()
    pipeline.statesOnStart = [.starting, .unavailable(.camera)]
    let service = SafetyService(pipeline: pipeline, audioArbiter: arbiter)

    // Sin ruta activa (nunca se pidió la detección) el reintento no enciende la cámara.
    await service.retry()
    #expect(pipeline.starts == 0)

    try await service.start()
    await eventually { service.status == .unavailable(.camera) }
    pipeline.statesOnStart = [.starting, .running]
    await service.retry()
    await eventually { service.status == .running }

    #expect(pipeline.starts == 2)
    #expect(pipeline.stops == 1)
    service.stop()
}
// SCRUM-314: «cámara lista» por audio y vibración, una vez por ruta, solo con la seguridad
// funcionando.

@Test @MainActor func cameraReadyIsSpokenAndVibratedOnceWhenSafetyRuns() async throws {
    let arbiter = SpyArbiter()
    let haptics = SpyHaptics()
    let service = SafetyService(
        pipeline: FakeObstaclePipeline(isDepthAvailable: true), audioArbiter: arbiter, haptics: haptics
    )

    try await service.start()
    await eventually { service.status == .running }

    let ready = arbiter.received.filter { $0.text.hasPrefix(SafetyAudio.readyPrefix) }
    #expect(ready.count == 1)
    #expect(ready.first?.priority == .routeInformation)
    #expect(haptics.cues == [.safetyReady])
    service.stop()
}

@Test @MainActor func cameraReadyIsNotAnnouncedWhenDetectionCannotStart() async throws {
    let arbiter = SpyArbiter()
    let haptics = SpyHaptics()
    let pipeline = FakeObstaclePipeline()
    pipeline.statesOnStart = [.starting, .unavailable(.camera)]
    let service = SafetyService(pipeline: pipeline, audioArbiter: arbiter, haptics: haptics)

    try await service.start()
    await eventually { service.status == .unavailable(.camera) }

    #expect(!arbiter.received.contains { $0.text.hasPrefix(SafetyAudio.readyPrefix) })
    #expect(haptics.cues.isEmpty)
    // Se informa por audio que la detección no está disponible.
    #expect(arbiter.received.contains { $0.deduplicationKey == "safety-unavailable" })
    service.stop()
}
#endif
