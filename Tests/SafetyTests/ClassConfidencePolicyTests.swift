import Testing
@testable import LumioFrontend

// MARK: - Per-class thresholds

@Test func personThresholdIsHighestToReduceFalsePositives() {
    let policy = ClassConfidencePolicy.default
    #expect(policy.threshold(for: .person) == 0.55)
}

@Test func vehiclesHaveModerateThreshold() {
    let policy = ClassConfidencePolicy.default
    for cls: ObstacleClass in [.car, .motorcycle, .bus, .truck, .bicycle] {
        #expect(policy.threshold(for: cls) == 0.50, "expected 0.50 for \(cls)")
    }
}

@Test func staticObstaclesHaveLowestThreshold() {
    let policy = ClassConfidencePolicy.default
    for cls: ObstacleClass in [.chair, .bench, .pottedPlant] {
        #expect(policy.threshold(for: cls) == 0.45, "expected 0.45 for \(cls)")
    }
}

@Test func unllistedClassGetsFallback() {
    let policy = ClassConfidencePolicy.default
    // trafficLight, fireHydrant, stopSign, parkingMeter, dog are not in overrides
    for cls: ObstacleClass in [.trafficLight, .fireHydrant, .stopSign, .parkingMeter, .dog] {
        #expect(policy.threshold(for: cls) == policy.fallback, "expected fallback for \(cls)")
    }
}

@Test func personThresholdHigherThanVehicle() {
    let policy = ClassConfidencePolicy.default
    #expect(policy.threshold(for: .person) > policy.threshold(for: .car))
}

@Test func vehicleThresholdHigherThanStaticObstacle() {
    let policy = ClassConfidencePolicy.default
    #expect(policy.threshold(for: .car) > policy.threshold(for: .chair))
}
