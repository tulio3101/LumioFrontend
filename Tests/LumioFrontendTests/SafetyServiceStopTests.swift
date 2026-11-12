#if os(iOS)
import Testing
@testable import LumioFrontend

// SCRUM-33: al parar, SafetyService cancela solo su contexto de audio ("safety") en vez de
// resetear toda la sesión, para no pisar el audio de navegación.

final class FakeObstaclePipeline: ObstacleDetectionPipeline, @unchecked Sendable {
    let detections: AsyncStream<[Detection]>
    private let continuation: AsyncStream<[Detection]>.Continuation
    var isDepthAvailable: Bool
    private(set) var starts = 0
    private(set) var stops = 0

    init(isDepthAvailable: Bool = true) {
        self.isDepthAvailable = isDepthAvailable
        var captured: AsyncStream<[Detection]>.Continuation!
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
#endif
