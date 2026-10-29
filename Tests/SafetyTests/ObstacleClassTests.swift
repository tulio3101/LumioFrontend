import Testing
import CoreGraphics
@testable import LumioFrontend

// MARK: - ObstacleClass mapping

@Test func allMobilityClassesMapFromCocoLabel() {
    let cases: [(String, ObstacleClass)] = [
        ("person",        .person),
        ("bicycle",       .bicycle),
        ("car",           .car),
        ("motorcycle",    .motorcycle),
        ("bus",           .bus),
        ("truck",         .truck),
        ("traffic light", .trafficLight),
        ("fire hydrant",  .fireHydrant),
        ("stop sign",     .stopSign),
        ("parking meter", .parkingMeter),
        ("bench",         .bench),
        ("chair",         .chair),
        ("dog",           .dog),
        ("potted plant",  .pottedPlant),
        // Interior COCO classes added for indoor navigation
        ("dining table",  .diningTable),
        ("bed",           .bed),
        ("couch",         .couch),
        ("toilet",        .toilet),
        ("refrigerator",  .refrigerator),
        ("tv",            .tv),
        ("laptop",        .laptop),
        ("suitcase",      .suitcase),
        ("backpack",      .backpack),
        ("umbrella",      .umbrella),
    ]
    for (label, expected) in cases {
        #expect(ObstacleClass.from(cocoLabel: label) == expected)
    }
}

@Test func nonMobilityCocoClassesReturnNil() {
    // couch/bed/refrigerator removed — they are now mobility classes.
    let nonMobility = [
        "airplane", "cat", "toothbrush", "boat", "sheep", "cow", "horse", "",
    ]
    for label in nonMobility {
        #expect(ObstacleClass.from(cocoLabel: label) == nil)
    }
}

@Test func mappingIsCaseSensitive() {
    #expect(ObstacleClass.from(cocoLabel: "Person") == nil)
    #expect(ObstacleClass.from(cocoLabel: "PERSON") == nil)
    #expect(ObstacleClass.from(cocoLabel: "Car") == nil)
    #expect(ObstacleClass.from(cocoLabel: "Traffic Light") == nil)
}

// MARK: - Detection

@Test func detectionDefaultDistanceIsNil() {
    let det = Detection(
        obstacleClass: .person,
        confidence: 0.9,
        boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.4)
    )
    #expect(det.distanceMeters == nil)
    #expect(det.obstacleClass == .person)
    #expect(abs(det.confidence - 0.9) < 0.001)
}

@Test func detectionCanBeEnrichedWithDistance() {
    var det = Detection(
        obstacleClass: .car,
        confidence: 0.85,
        boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
    )
    det.distanceMeters = 2.5
    #expect(det.distanceMeters == 2.5)
}

@Test func detectionBoundingBoxOriginIsTopLeft() {
    // Contract: x=0,y=0 is top-left, x=1,y=1 is bottom-right.
    // A box in the top-left quadrant has small x and y values.
    let topLeftBox = CGRect(x: 0.0, y: 0.0, width: 0.3, height: 0.3)
    let det = Detection(obstacleClass: .bench, confidence: 0.7, boundingBox: topLeftBox)
    #expect(det.boundingBox.minX < 0.5)
    #expect(det.boundingBox.minY < 0.5)
}
