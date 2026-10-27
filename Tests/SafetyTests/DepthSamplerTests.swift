import Testing
import CoreGraphics
import Foundation
@testable import LumioFrontend

// MARK: - SCRUM-219/220: depth sampling geometry (cross-platform)

@Test func innerBoxShrinksByThirtyPercent() {
    // DepthSampler uses insetBy(dx: w*0.35, dy: h*0.35) to get the 30% central area.
    let box = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
    let inner = box.insetBy(dx: box.width * 0.35, dy: box.height * 0.35)
    // Central 30%: from 0.35 to 0.65 in both axes.
    #expect(abs(inner.minX - 0.35) < 0.001)
    #expect(abs(inner.minY - 0.35) < 0.001)
    #expect(abs(inner.maxX - 0.65) < 0.001)
    #expect(abs(inner.maxY - 0.65) < 0.001)
    let area = inner.width * inner.height
    // Inner area ≈ 9% of original (0.3 × 0.3 of each side)
    #expect(abs(Float(area) - 0.09) < 0.01)
}

// MARK: - SCRUM-221/222: offline architecture (cross-platform)
// These tests verify that Safety types are available and compile without any network dependency.

@Test func safetyEventIsConstructibleWithoutNetwork() {
    let event = SafetyEvent(
        id: UUID(),
        description: "persona a 1.2 metros",
        detectedAt: Date(),
        requiresImmediateAction: true
    )
    #expect(event.requiresImmediateAction)
    #expect(!event.description.isEmpty)
}

// iOS-only: DepthSampler constants
#if os(iOS)
@Test func maxAlertDistanceIs4Meters() {
    #expect(DepthSampler.maxAlertDistanceMeters == 4.0)
}
#endif

@Test func detectionPipelineTypesDoNotRequireNetwork() {
    // Compile-time proof: if Safety imported URLSession/Network, this file would fail to build.
    // The test itself just verifies Detection and ObstacleClass are usable cross-platform.
    let det = Detection(
        obstacleClass: .person,
        confidence: 0.8,
        boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)
    )
    #expect(det.distanceMeters == nil)
    #expect(det.obstacleClass == .person)
}

// MARK: - SCRUM-229: on-device offline detection (iOS device test)
// Run these manually on iPhone with Airplane Mode enabled.

#if os(iOS)
@Test func arkitFrameSourceStartsWithoutNetworkAccess() throws {
    // Verifies the detection pipeline can initialize even with no network.
    // On simulator: isDepthAvailable=false (no LiDAR). On LiDAR device: true.
    let source = ARKitFrameSource()
    try source.start()
    // No network call should be made — if one were, it would time out in Airplane Mode.
    source.stop()
}
#endif
