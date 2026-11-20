#if os(iOS)
import Testing
@testable import LumioFrontend

// SCRUM-33: al parar, SafetyService cancela solo su contexto de audio ("safety") en vez de
// resetear toda la sesión, para no pisar el audio de navegación.

final class FakeObstaclePipeline: ObstacleDetectionPipeline, @unchecked Sendable {
    let detections: AsyncStream<SafetyFrameOutput>
    private let continuation: AsyncStream<SafetyFrameOutput>.Continuation
    var isDepthAvailable: Bool
    private(set) var starts = 0
    private(set) var stops = 0

    init(isDepthAvailable: Bool = true) {
        self.isDepthAvailable = isDepthAvailable
        var captured: AsyncStream<SafetyFrameOutput>.Continuation!
        detections = AsyncStream { captured = $0 }
        continuation = captured
    }

    func start() throws { starts += 1 }
    func stop() { stops += 1; continuation.finish() }
    #if DEBUG
    var previewFrameSource: ARKitFrameSource? { nil }
    #endif
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
}

// SCRUM-320: el usuario sabe por audio si opera en modo completo (LiDAR) o reducido (sin LiDAR).

@Test @MainActor func announcesFullModeOnLidarDevice() async throws {
    let arbiter = SpyArbiter()
    let service = SafetyService(pipeline: FakeObstaclePipeline(isDepthAvailable: true), audioArbiter: arbiter)

    try await service.start()
    service.stop()

    #expect(arbiter.received.contains { $0.deduplicationKey == "safety-mode-full" })
    #expect(!arbiter.received.contains { $0.deduplicationKey == "safety-mode-reduced" })
}

@Test @MainActor func announcesReducedModeWithoutLidar() async throws {
    let arbiter = SpyArbiter()
    let service = SafetyService(pipeline: FakeObstaclePipeline(isDepthAvailable: false), audioArbiter: arbiter)

    try await service.start()
    service.stop()

    #expect(arbiter.received.contains { $0.deduplicationKey == "safety-mode-reduced" })
    #expect(!arbiter.received.contains { $0.deduplicationKey == "safety-mode-full" })
}
#endif
