import Testing
import CoreGraphics
import Foundation
@testable import LumioFrontend

// SCRUM-33: el anuncio es por objeto rastreado (TrackedDetection.id), con cooldown por objeto,
// reaviso solo cuando sube de nivel y silencio de los estáticos ya anunciados. Los AudioMessage
// llevan contextID "safety", número de captura y una deduplicationKey por objeto.

private func tracked(
    _ cls: ObstacleClass, id: Int, meters: Float?, approaching: Bool = false
) -> TrackedDetection {
    TrackedDetection(
        id: id,
        detection: Detection(
            obstacleClass: cls, confidence: 0.9,
            boundingBox: CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.3),
            distanceMeters: meters
        ),
        isApproaching: approaching
    )
}

private let t0 = Date(timeIntervalSince1970: 1_000)

@Test func obstacleMessageCarriesSafetyContextObjectKeyAndCapture() {
    var announcer = ObstacleAnnouncer()
    let outputs = announcer.announcements(for: [tracked(.chair, id: 1, meters: 2.0)], now: t0)

    let message = try! #require(outputs.first).message
    #expect(message.contextID == "safety")
    #expect(message.deduplicationKey == "obstacle-chair-1")
    #expect(message.captureSequence == 1)
    #expect(message.priority == .environmentInformation) // 1–4 m
    #expect(message.text == "silla a 2,0 metros")
}

@Test func closeObstacleInterruptsAsImmediateRisk() {
    var announcer = ObstacleAnnouncer()
    let output = try! #require(
        announcer.announcements(for: [tracked(.person, id: 1, meters: 0.5)], now: t0).first
    )
    #expect(output.message.priority == .immediateRisk)
    #expect(output.event.requiresImmediateAction)
}

@Test func captureSequenceIncrementsPerFrame() {
    var announcer = ObstacleAnnouncer()
    // Dos objetos distintos en frames distintos: ambos anuncian (primera vez cada uno).
    let first = announcer.announcements(for: [tracked(.car, id: 1, meters: 5.0)], now: t0)
    let second = announcer.announcements(for: [tracked(.car, id: 2, meters: 5.0)], now: t0.addingTimeInterval(5))

    #expect(try! #require(first.first).message.captureSequence == 1)
    #expect(try! #require(second.first).message.captureSequence == 2)
}

@Test func staticObjectIsAnnouncedOnceThenSilenced() {
    var announcer = ObstacleAnnouncer()
    // Primera vez: anuncia.
    #expect(!announcer.announcements(for: [tracked(.car, id: 1, meters: 5.0)], now: t0).isEmpty)
    // Mismo objeto, quieto (no se acerca), mismo tramo: no vuelve a anunciar aunque pase el cooldown.
    let again = announcer.announcements(for: [tracked(.car, id: 1, meters: 5.0)], now: t0.addingTimeInterval(10))
    #expect(again.isEmpty)
}

@Test func approachingObjectReannouncesAfterCooldown() {
    var announcer = ObstacleAnnouncer(announcementInterval: 4.0)
    #expect(!announcer.announcements(for: [tracked(.car, id: 1, meters: 3.0, approaching: true)], now: t0).isEmpty)
    // Sigue acercándose y venció el cooldown → vuelve a anunciar.
    let later = announcer.announcements(
        for: [tracked(.car, id: 1, meters: 2.0, approaching: true)], now: t0.addingTimeInterval(5)
    )
    #expect(!later.isEmpty)
}

@Test func levelUpReannouncesEvenWithinCooldown() {
    var announcer = ObstacleAnnouncer()
    // Primera vez en tramo normal (2 m).
    _ = announcer.announcements(for: [tracked(.person, id: 1, meters: 2.0)], now: t0)
    // Sube a peligro (0,5 m) dentro del cooldown y sin "approaching": reanuncia por escalada.
    let escalated = announcer.announcements(for: [tracked(.person, id: 1, meters: 0.5)], now: t0.addingTimeInterval(1))
    let message = try! #require(escalated.first).message
    #expect(message.priority == .immediateRisk)
}

@Test func depthObstacleAnnouncementTextAndPriority() {
    let announcer = ObstacleAnnouncer()
    // Pared cercana (<1 m) → peligro inmediato.
    let near = announcer.depthObstacleOutput(kind: .wall, distanceMeters: 0.8, now: t0)
    #expect(near.message.text == "pared al frente, a 0,8 metros")
    #expect(near.message.priority == .immediateRisk)
    #expect(near.message.deduplicationKey == "depth-wall")
    // Mesa a media distancia → información del entorno.
    let mid = announcer.depthObstacleOutput(kind: .table, distanceMeters: 2.0, now: t0)
    #expect(mid.message.text == "mesa al frente, a 2,0 metros")
    #expect(mid.message.priority == .environmentInformation)
}

@Test func deduplicationPolicyDiscardsOlderAndRepeatedCaptures() {
    var announcer = ObstacleAnnouncer()
    let older = try! #require(
        announcer.announcements(for: [tracked(.car, id: 1, meters: 3.0, approaching: true)], now: t0).first
    ).message
    let newer = try! #require(
        announcer.announcements(
            for: [tracked(.car, id: 1, meters: 2.0, approaching: true)], now: t0.addingTimeInterval(5)
        ).first
    ).message

    let policy = AudioDeduplicationPolicy()
    #expect(policy.isNewerCapture(newer, than: older))
    #expect(!policy.isNewerCapture(older, than: newer))
    #expect(policy.isDuplicate(older, of: newer))
    #expect(!policy.isDuplicate(newer, of: older))
}
