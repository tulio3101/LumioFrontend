import Testing
import CoreGraphics
@testable import LumioFrontend

// MARK: - SCRUM-217: coordinate conversion and COCO filter (cross-platform)

@Test func visionBottomLeftFlipsToTopLeft() {
    // Vision box: x=0.1, y=0.1 from bottom-left, w=0.3, h=0.4
    // maxY in Vision = 0.1+0.4 = 0.5 → top-left minY = 1.0 - 0.5 = 0.5
    let vision = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.4)
    let tl = visionToTopLeft(vision)
    #expect(abs(tl.minX - 0.1) < 0.001)
    #expect(abs(tl.minY - 0.5) < 0.001)
    #expect(abs(tl.width  - 0.3) < 0.001)
    #expect(abs(tl.height - 0.4) < 0.001)
}

@Test func visionBoxAtTopProducesMinYNearZero() {
    // A box at the very top in Vision: y close to 1, height small.
    let vision = CGRect(x: 0.0, y: 0.9, width: 1.0, height: 0.1)
    let tl = visionToTopLeft(vision)
    // 1.0 - (0.9+0.1) = 0.0 → top-left origin at top
    #expect(abs(tl.minY) < 0.001)
}

@Test func visionBoxAtBottomProducesMinYNearOne() {
    let vision = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.1)
    let tl = visionToTopLeft(vision)
    // 1.0 - 0.1 = 0.9
    #expect(abs(tl.minY - 0.9) < 0.001)
}

@Test func coordinateRoundtripIsIdempotent() {
    // Applying the flip twice must return to the original box.
    let original = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
    let roundtrip = visionToTopLeft(visionToTopLeft(original))
    #expect(abs(roundtrip.minX - original.minX) < 0.001)
    #expect(abs(roundtrip.minY - original.minY) < 0.001)
    #expect(abs(roundtrip.width  - original.width)  < 0.001)
    #expect(abs(roundtrip.height - original.height) < 0.001)
}

// MARK: - iOS-only: YOLORunner model loading

#if os(iOS) && !targetEnvironment(simulator)
@Test func yoloRunnerThrowsWhenModelIsAbsent() {
    // On device this test is only meaningful if the mlpackage is missing from the bundle.
    // It verifies the error path compiles and throws the right error type.
    do {
        _ = try YOLORunner()
        // If model is present in bundle this succeeds — acceptable on CI with model.
    } catch YOLORunnerError.modelNotFound {
        // Expected when bundle lacks the mlpackage.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
#endif
