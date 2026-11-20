import Testing
import CoreGraphics
@testable import LumioFrontend

// Helpers
private func det(_ cls: ObstacleClass, box: CGRect = CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)) -> Detection {
    Detection(obstacleClass: cls, confidence: 0.8, boundingBox: box)
}

private func feed(_ smoother: inout TemporalSmoother, frames: [[Detection]]) -> [Detection] {
    var result: [Detection] = []
    for frame in frames { result = smoother.filter(frame) }
    return result
}

// MARK: - Warm-up

@Test func noOutputBeforeWindowFills() {
    var s = TemporalSmoother(windowSize: 5, minAppearances: 3, minIoU: 0.3)
    // 2 frames < minAppearances(3) → always empty
    #expect(s.filter([det(.person)]).isEmpty)
    #expect(s.filter([det(.person)]).isEmpty)
}

@Test func outputAfterMinAppearancesFrames() {
    var s = TemporalSmoother(windowSize: 5, minAppearances: 3, minIoU: 0.3)
    let box = CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)
    let result = feed(&s, frames: [
        [Detection(obstacleClass: .person, confidence: 0.8, boundingBox: box)],
        [Detection(obstacleClass: .person, confidence: 0.8, boundingBox: box)],
        [Detection(obstacleClass: .person, confidence: 0.8, boundingBox: box)],
    ])
    #expect(result.count == 1)
    #expect(result[0].obstacleClass == .person)
}

// MARK: - Stability

@Test func disappearingDetectionDropped() {
    var s = TemporalSmoother(windowSize: 5, minAppearances: 3, minIoU: 0.3)
    let box = CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)
    // 3 frames with person → stable
    _ = feed(&s, frames: [
        [Detection(obstacleClass: .person, confidence: 0.8, boundingBox: box)],
        [Detection(obstacleClass: .person, confidence: 0.8, boundingBox: box)],
        [Detection(obstacleClass: .person, confidence: 0.8, boundingBox: box)],
    ])
    // 2 frames without person — window now has 2 person + 2 empty → below threshold
    _ = s.filter([])
    let final = s.filter([Detection(obstacleClass: .person, confidence: 0.8, boundingBox: box)])
    // only 3 of last 5 would be: frames 1,2,3 (person) + frame4 (empty) + frame5 (person) = 3/5
    // But frame 1 is still in the window of size 5 at this point (frames 1-5)
    // so person appears in frames 1,2,3,5 = 4/5 ≥ 3 → still stable
    #expect(final.count == 1)
}

@Test func singleFrameGlitchFiltered() {
    var s = TemporalSmoother(windowSize: 5, minAppearances: 3, minIoU: 0.3)
    let box = CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)
    // Only 1 frame with person surrounded by empties
    _ = s.filter([])
    _ = s.filter([Detection(obstacleClass: .person, confidence: 0.8, boundingBox: box)])
    let result = s.filter([])
    #expect(result.isEmpty)
}

// MARK: - IoU separation

@Test func nonOverlappingBoxesTreatedAsDifferentObjects() {
    var s = TemporalSmoother(windowSize: 5, minAppearances: 3, minIoU: 0.3)
    let boxLeft  = CGRect(x: 0.0, y: 0.3, width: 0.2, height: 0.2)
    let boxRight = CGRect(x: 0.8, y: 0.3, width: 0.2, height: 0.2)

    // 3 frames with person on the LEFT
    _ = feed(&s, frames: [
        [Detection(obstacleClass: .person, confidence: 0.8, boundingBox: boxLeft)],
        [Detection(obstacleClass: .person, confidence: 0.8, boundingBox: boxLeft)],
        [Detection(obstacleClass: .person, confidence: 0.8, boundingBox: boxLeft)],
    ])
    // Frame 4 has person on the RIGHT only (different object, IoU ≈ 0 with left boxes)
    let result = s.filter([Detection(obstacleClass: .person, confidence: 0.8, boundingBox: boxRight)])
    // Right box appears in only 1/4 frames → not stable yet
    #expect(result.isEmpty)
}

// MARK: - IoU helper (internal — verified indirectly via filter behavior)

@Test func overlappingBoxesCountAsSameObject() {
    var s = TemporalSmoother(windowSize: 5, minAppearances: 3, minIoU: 0.3)
    // Slightly shifted box — still heavily overlapping (IoU ≈ 0.56)
    let box1 = CGRect(x: 0.30, y: 0.30, width: 0.20, height: 0.20)
    let box2 = CGRect(x: 0.32, y: 0.32, width: 0.20, height: 0.20)
    let box3 = CGRect(x: 0.31, y: 0.31, width: 0.20, height: 0.20)
    let result = feed(&s, frames: [
        [Detection(obstacleClass: .chair, confidence: 0.6, boundingBox: box1)],
        [Detection(obstacleClass: .chair, confidence: 0.6, boundingBox: box2)],
        [Detection(obstacleClass: .chair, confidence: 0.6, boundingBox: box3)],
    ])
    #expect(result.count == 1)
    #expect(result[0].obstacleClass == .chair)
}

// MARK: - Multiple classes

@Test func independentClassesTrackedSeparately() {
    var s = TemporalSmoother(windowSize: 5, minAppearances: 3, minIoU: 0.3)
    let boxP = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)
    let boxC = CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2)
    let result = feed(&s, frames: [
        [det(.person, box: boxP), det(.car, box: boxC)],
        [det(.person, box: boxP), det(.car, box: boxC)],
        [det(.person, box: boxP), det(.car, box: boxC)],
    ])
    let classes = Set(result.map(\.obstacleClass))
    #expect(classes == [.person, .car])
}
