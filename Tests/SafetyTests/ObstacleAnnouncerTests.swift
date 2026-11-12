import Testing
import CoreGraphics
import Foundation
@testable import LumioFrontend

// SCRUM-33: los AudioMessage de obstáculos llevan contextID "safety", número de captura
// (frame) y deduplicationKey por clase, para que AudioDeduplicationPolicy descarte las
// capturas viejas y las repetidas.

private func detection(_ cls: ObstacleClass, meters: Float?) -> Detection {
    Detection(
        obstacleClass: cls,
        confidence: 0.9,
        boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3),
        distanceMeters: meters
    )
}

private let t0 = Date(timeIntervalSince1970: 1_000)

@Test func obstacleMessageCarriesSafetyContextClassKeyAndCapture() {
    var announcer = ObstacleAnnouncer()
    let outputs = announcer.announcements(for: [detection(.chair, meters: 2.0)], now: t0)

    let message = try! #require(outputs.first).message
    #expect(message.contextID == "safety")
    #expect(message.deduplicationKey == "obstacle-chair")
    #expect(message.captureSequence == 1)
    #expect(message.priority == .environmentInformation) // 1–4 m
    #expect(message.text == "silla a 2,0 metros")
}

@Test func closeObstacleInterruptsAsImmediateRisk() {
    var announcer = ObstacleAnnouncer()
    let output = try! #require(announcer.announcements(for: [detection(.person, meters: 0.5)], now: t0).first)
    #expect(output.message.priority == .immediateRisk)
    #expect(output.event.requiresImmediateAction)
}

@Test func captureSequenceIncrementsPerFrame() {
    var announcer = ObstacleAnnouncer()
    // Dos frames separados más que el intervalo de throttle: ambos anuncian.
    let first = announcer.announcements(for: [detection(.car, meters: 5.0)], now: t0)
    let second = announcer.announcements(for: [detection(.car, meters: 5.0)], now: t0.addingTimeInterval(5))

    #expect(try! #require(first.first).message.captureSequence == 1)
    #expect(try! #require(second.first).message.captureSequence == 2)
}

@Test func throttleSkipsSameTierWithinInterval() {
    var announcer = ObstacleAnnouncer()
    _ = announcer.announcements(for: [detection(.car, meters: 5.0)], now: t0)
    // Mismo tramo de distancia, dentro del intervalo → no vuelve a anunciar.
    let again = announcer.announcements(for: [detection(.car, meters: 5.0)], now: t0.addingTimeInterval(1))
    #expect(again.isEmpty)
}

@Test func deduplicationPolicyDiscardsOlderAndRepeatedCaptures() {
    var announcer = ObstacleAnnouncer()
    let older = try! #require(announcer.announcements(for: [detection(.car, meters: 5.0)], now: t0).first).message
    let newer = try! #require(
        announcer.announcements(for: [detection(.car, meters: 5.0)], now: t0.addingTimeInterval(5)).first
    ).message

    let policy = AudioDeduplicationPolicy()
    // La captura más nueva supera a la vieja...
    #expect(policy.isNewerCapture(newer, than: older))
    #expect(!policy.isNewerCapture(older, than: newer))
    // ...así que la vieja se trata como duplicada (se descarta) y la nueva no.
    #expect(policy.isDuplicate(older, of: newer))
    #expect(!policy.isDuplicate(newer, of: older))
}
