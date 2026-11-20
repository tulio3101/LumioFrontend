import Testing
import CoreGraphics
@testable import LumioFrontend

// SCRUM-33: relevancia por acercamiento. El tracker marca isApproaching cuando la distancia al
// objeto decrece de forma sostenida; un objeto estático queda como no-acercándose.

private let box = CGRect(x: 0.45, y: 0.60, width: 0.10, height: 0.20)

private func det(meters: Float) -> Detection {
    Detection(obstacleClass: .person, confidence: 0.9, boundingBox: box, distanceMeters: meters)
}

@Test func decreasingDistanceMarksApproaching() {
    var tracker = ObstacleTracker()
    _ = tracker.update([det(meters: 3.0)])
    _ = tracker.update([det(meters: 2.5)])
    let out = try! #require(tracker.update([det(meters: 2.0)]).first)   // 3 apariciones → emite
    #expect(out.isApproaching)
}

@Test func stableDistanceIsNotApproaching() {
    var tracker = ObstacleTracker()
    _ = tracker.update([det(meters: 3.0)])
    _ = tracker.update([det(meters: 3.0)])
    let out = try! #require(tracker.update([det(meters: 3.0)]).first)
    #expect(!out.isApproaching)
}

@Test func recedingDistanceIsNotApproaching() {
    var tracker = ObstacleTracker()
    _ = tracker.update([det(meters: 2.0)])
    _ = tracker.update([det(meters: 2.5)])
    let out = try! #require(tracker.update([det(meters: 3.0)]).first)
    #expect(!out.isApproaching)
}
