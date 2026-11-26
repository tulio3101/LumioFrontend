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

@Test func confusingObjectsHaveRaisedThreshold() {
    // Objetos pequeños / fáciles de confundir: umbral alto para cortar falsos positivos.
    let policy = ClassConfidencePolicy.default
    for cls: ObstacleClass in [.chair, .pottedPlant, .backpack, .suitcase, .umbrella] {
        #expect(policy.threshold(for: cls) == 0.55, "expected 0.55 for \(cls)")
    }
}

@Test func benchHasModerateThreshold() {
    let policy = ClassConfidencePolicy.default
    #expect(policy.threshold(for: .bench) == 0.50)
}

@Test func unllistedClassGetsFallback() {
    let policy = ClassConfidencePolicy.default
    // trafficLight, fireHydrant, stopSign, parkingMeter are not in overrides
    for cls: ObstacleClass in [.trafficLight, .fireHydrant, .stopSign, .parkingMeter] {
        #expect(policy.threshold(for: cls) == policy.fallback, "expected fallback for \(cls)")
    }
}

// SCRUM-33 corrección 6: perro con umbral bajo (parcialmente visible cerca del borde).
@Test func dogHasLowThreshold() {
    #expect(ClassConfidencePolicy.default.threshold(for: .dog) == 0.35)
}

@Test func personThresholdHigherThanVehicle() {
    let policy = ClassConfidencePolicy.default
    #expect(policy.threshold(for: .person) > policy.threshold(for: .car))
}

@Test func confusingObjectThresholdHigherThanVehicle() {
    let policy = ClassConfidencePolicy.default
    #expect(policy.threshold(for: .chair) > policy.threshold(for: .car))
}
