import Testing
@testable import LumioFrontend

// MARK: - Cross-platform: "latest frame wins" buffering policy

@Test func latestFrameWinsWhenConsumerIsLate() async {
    var continuation: AsyncStream<Int>.Continuation!
    let stream = AsyncStream<Int>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }

    // Yield 3 values before the consumer starts reading.
    // With bufferingNewest(1): 1 is evicted when 2 arrives, 2 is evicted when 3 arrives.
    continuation.yield(1)
    continuation.yield(2)
    continuation.yield(3)
    continuation.finish()

    var received: [Int] = []
    for await value in stream { received.append(value) }

    #expect(received == [3])
}

// MARK: - iOS-only: CapturedFrame and ARKitFrameSource

#if os(iOS)
import ARKit
import AVFoundation
import CoreVideo

@Test func capturedFrameWithNilDepthRepresentsNonLidarPath() {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    guard let buffer = pixelBuffer else { Issue.record("CVPixelBuffer allocation failed"); return }

    let frame = CapturedFrame(pixelBuffer: buffer, depthData: nil, camera: nil, timestamp: 0)
    #expect(frame.depthData == nil)
    #expect(frame.camera == nil)
    #expect(frame.timestamp == 0)
}

@Test func arkitFrameSourceDepthUnavailableBeforeStart() {
    let source = ARKitFrameSource()
    #expect(!source.isDepthAvailable)
}

@Test(.enabled(if: ARWorldTrackingConfiguration.isSupported && AVCaptureDevice.authorizationStatus(for: .video) == .authorized)) func arkitFrameSourceDepthAvailabilityMatchesHardware() throws {
    let source = ARKitFrameSource()
    try source.start()
    let expected = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    #expect(source.isDepthAvailable == expected)
    source.stop()
}
#endif
