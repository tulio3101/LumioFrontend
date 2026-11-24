#if os(iOS)
import CoreVideo
import Foundation
import Testing
@testable import LumioFrontend

private final class SyntheticFrames: FrameSource {
    let isDepthAvailable = false
    private(set) var frames: AsyncStream<CapturedFrame>
    private var continuation: AsyncStream<CapturedFrame>.Continuation
    var onStart: (() -> Void)?
    private(set) var starts = 0
    private(set) var completedFrames = 0
    init() {
        let channel = makeSafetyStream(of: CapturedFrame.self, bufferingPolicy: .bufferingNewest(1))
        frames = channel.stream
        continuation = channel.continuation
    }
    func start() throws {
        let channel = makeSafetyStream(of: CapturedFrame.self, bufferingPolicy: .bufferingNewest(1))
        frames = channel.stream
        continuation = channel.continuation
        starts += 1
        let callback = onStart
        onStart = nil
        callback?()
    }
    func stop() { continuation.finish() }
    func frameProcessingComplete() { completedFrames += 1 }
    func send(_ buffer: CVPixelBuffer) {
        continuation.yield(CapturedFrame(pixelBuffer: buffer, depthData: nil, camera: nil, timestamp: 1))
    }
    func fail() { continuation.finish() }
}

private final class SyntheticDetector: ObstacleDetecting {
    func detect(pixelBuffer: CVPixelBuffer) throws -> [Detection] {
        [Detection(obstacleClass: .person, confidence: 0.9,
                   boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))]
    }
}

private final class FailingDetector: ObstacleDetecting {
    func detect(pixelBuffer: CVPixelBuffer) throws -> [Detection] {
        throw DetectionModelError.inferenceFailed
    }
}

@MainActor
private func startSynthetic(_ pipeline: DetectionPipeline, _ source: SyntheticFrames) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        source.onStart = { continuation.resume() }
        Task { await pipeline.start() }
    }
}

private func syntheticBuffer() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let result = CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
    #expect(result == kCVReturnSuccess)
    return try #require(buffer)
}

@Test @MainActor func missingModelDoesNotStartCameraAndPublishesUnavailable() async {
    let source = SyntheticFrames()
    let pipeline = DetectionPipeline(frameSource: source, runnerFactory: { throw DetectionModelError.modelNotFound })
    await pipeline.start()
    var states: [SafetyStatus] = []
    for await value in pipeline.statusUpdates { states.append(value) }
    #expect(states == [.starting, .unavailable(.model(.modelNotFound))])
    #expect(source.starts == 0)
    pipeline.stop()
}

@Test @MainActor func pipelineCanStopAndRestartWithFreshStreamsWithoutDepth() async throws {
    let source = SyntheticFrames()
    let pipeline = DetectionPipeline(frameSource: source, runnerFactory: { SyntheticDetector() })
    let buffer = try syntheticBuffer()
    for _ in 0..<2 {
        await startSynthetic(pipeline, source)
        var results = pipeline.detections.makeAsyncIterator()
        var states = pipeline.statusUpdates.makeAsyncIterator()
        source.send(buffer)
        // Sin profundidad la detección sigue: llega una salida por frame (el rastreo exige
        // persistencia, así que con un solo frame puede no haber objetos confirmados).
        let output = await results.next()
        #expect(output != nil)
        #expect(output?.depthObstacles.isEmpty == true)
        #expect(await states.next() == .starting)
        #expect(await states.next() == .running)
        pipeline.stop()
    }
    #expect(source.starts == 2)
    #expect(source.completedFrames == 2)
}

// Una inferencia fallida no se publica como escena vacía: el frame se descarta.
@Test @MainActor func failedInferenceDropsFrameInsteadOfReportingEmptyScene() async throws {
    let source = SyntheticFrames()
    let pipeline = DetectionPipeline(
        frameSource: source,
        runnerFactory: { FailingDetector() },
        recoveryPolicy: ModelRecoveryPolicy(delays: [])
    )
    await startSynthetic(pipeline, source)
    source.send(try syntheticBuffer())
    var states: [SafetyStatus] = []
    for await value in pipeline.statusUpdates { states.append(value) }
    var outputs = 0
    for await _ in pipeline.detections { outputs += 1 }
    #expect(states.last == .unavailable(.model(.inferenceFailed)))
    #expect(outputs == 0)
    #expect(source.completedFrames == 1)
    pipeline.stop()
}

@Test @MainActor func unexpectedCameraStreamEndIsNotAHealthyEmptyScene() async throws {
    let source = SyntheticFrames()
    let pipeline = DetectionPipeline(frameSource: source, runnerFactory: { SyntheticDetector() })
    await startSynthetic(pipeline, source)
    source.fail()
    var states: [SafetyStatus] = []
    for await value in pipeline.statusUpdates { states.append(value) }
    #expect(states.last == .unavailable(.camera))
    pipeline.stop()
}
#endif
