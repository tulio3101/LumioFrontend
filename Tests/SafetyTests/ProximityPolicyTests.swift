import Testing
import Foundation
@testable import LumioFrontend

// SCRUM-34: tabla de umbrales del spike SCRUM-309 con los rangos de confianza de ADR-307.

private let policy = ProximityPolicy()

private func lidar(_ meters: Float?, approaching: Bool = false) -> ProximityReading {
    policy.reading(distance: meters, isApproaching: approaching, mode: .lidar)
}

private func reduced(_ meters: Float?) -> ProximityReading {
    policy.reading(distance: meters, isApproaching: false, mode: .reduced)
}

// MARK: LiDAR

@Test func lidarStaticObstacleIsUrgentUpToTwoAndAHalfMeters() {
    #expect(lidar(0.4).level == .urgent)
    #expect(lidar(2.5).level == .urgent)
    #expect(lidar(2.6).level == .near)
}

@Test func lidarApproachingObstacleIsUrgentUpToThreeMeters() {
    #expect(lidar(2.9, approaching: true).level == .urgent)
    #expect(lidar(3.0, approaching: true).level == .urgent)
    #expect(lidar(3.1, approaching: true).level == .near)
}

@Test func lidarSaysMetersOnlyUpToThree() {
    #expect(lidar(2.0).speaksMeters)
    #expect(lidar(3.0).speaksMeters)
    #expect(lidar(3.01).speaksMeters == false)
    #expect(lidar(3.5).speaksMeters == false)
    // Urgente por acercamiento hasta 3,0 m: siempre con metros.
    #expect(lidar(3.0, approaching: true).speaksMeters)
}

@Test func lidarIsNearUpToFourMetersAndFarBeyond() {
    #expect(lidar(4.0).level == .near)
    #expect(lidar(4.01).level == .far)
    #expect(lidar(8.0).level == .far)
    #expect(lidar(8.0).speaksMeters == false)
}

@Test func withoutADistanceThereIsNoProximity() {
    #expect(lidar(nil) == ProximityReading(level: .unknown, speaksMeters: false))
    #expect(lidar(Float.nan).level == .unknown)
    #expect(lidar(-1).level == .unknown)
    #expect(reduced(nil).level == .unknown)
}

// MARK: Modo reducido (sin LiDAR)

@Test func reducedModeHasVeryCloseAndCloseOnly() {
    #expect(reduced(1.0).level == .urgent)
    #expect(reduced(1.49).level == .urgent)
    #expect(reduced(1.5).level == .near)
    #expect(reduced(2.5).level == .near)
}

@Test func reducedModeMakesNoPromiseBeyondTwoAndAHalfMeters() {
    #expect(reduced(2.6).level == .unknown)
    #expect(reduced(5.0).level == .unknown)
}

@Test func reducedModeNeverSpeaksMeters() {
    for meters: Float in [0.3, 1.0, 1.5, 2.0, 2.5, 4.0] {
        #expect(reduced(meters).speaksMeters == false)
    }
}

@Test func reducedUrgentThresholdStaysBelowOnePointFiveMeters() {
    // ADR-307: el umbral urgente del modo reducido debe caer dentro de 1,5 m.
    #expect(ProximityPolicy().reducedUrgentMeters <= 1.5)
    // Y el de LiDAR, dentro de 3 m para obstáculos estáticos.
    #expect(ProximityPolicy().urgentStaticMeters <= 3.0)
}

@Test func theApproachingFlagDoesNotChangeTheReducedMode() {
    let moving = policy.reading(distance: 2.0, isApproaching: true, mode: .reduced)
    #expect(moving == reduced(2.0))
}
