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
    let outputs = announcer.announcements(for: [tracked(.chair, id: 1, meters: 3.0)], now: t0)

    let message = try! #require(outputs.first).message
    #expect(message.contextID == "safety")
    #expect(message.deduplicationKey == "obstacle-chair-1")
    #expect(message.captureSequence == 1)
    #expect(message.priority == .environmentInformation) // cerca, fuera de la zona de riesgo
    #expect(message.text == "silla a 3,0 metros")
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
    // Primera vez en "cerca" (3,5 m, sin metros).
    _ = announcer.announcements(for: [tracked(.person, id: 1, meters: 3.5)], now: t0)
    // Entra en la zona de riesgo (2 m) dentro del cooldown y sin "approaching": reanuncia por escalada.
    let escalated = announcer.announcements(for: [tracked(.person, id: 1, meters: 2.0)], now: t0.addingTimeInterval(1))
    let message = try! #require(escalated.first).message
    #expect(message.priority == .immediateRisk)
}

@Test func depthObstacleAnnouncementTextAndPriority() {
    let announcer = ObstacleAnnouncer()
    // Pared en la zona de riesgo (≤ 2,5 m) → peligro inmediato.
    let near = announcer.depthObstacleOutput(kind: .wall, distanceMeters: 0.8, now: t0)
    #expect(near.message.text == "pared al frente, a 0,8 metros")
    #expect(near.message.priority == .immediateRisk)
    #expect(near.message.deduplicationKey == "depth-wall")
    let risk = announcer.depthObstacleOutput(kind: .table, distanceMeters: 2.0, now: t0)
    #expect(risk.message.text == "mesa al frente, a 2,0 metros")
    #expect(risk.message.priority == .immediateRisk)
    // Mesa a 2,8 m: cerca, con metros, sin urgencia → información del entorno.
    let mid = announcer.depthObstacleOutput(kind: .table, distanceMeters: 2.8, now: t0)
    #expect(mid.message.text == "mesa al frente, a 2,8 metros")
    #expect(mid.message.priority == .environmentInformation)
    // Entre 3 y 4 m el LiDAR ya no es exacto: «cerca», sin metros (ADR-307).
    let far = announcer.depthObstacleOutput(kind: .table, distanceMeters: 3.6, now: t0)
    #expect(far.message.text == "mesa al frente, cerca")
    #expect(far.message.priority == .environmentInformation)
}

// MARK: SCRUM-34: proximidad según el spike SCRUM-309

@Test func riskZoneAlertIsP1AndRequestsHaptics() {
    var announcer = ObstacleAnnouncer()
    let output = try! #require(
        announcer.announcements(for: [tracked(.person, id: 1, meters: 2.4)], now: t0).first
    )

    #expect(output.message.priority == .immediateRisk)
    #expect(output.message.text == "persona a 2,4 metros")
    // `requiresImmediateAction` es lo que hace vibrar a SafetyService.
    #expect(output.event.requiresImmediateAction)
}

@Test func anApproachingObjectIsUrgentFromThreeMeters() {
    var announcer = ObstacleAnnouncer()
    let staticOne = announcer.announcements(for: [tracked(.person, id: 1, meters: 2.9)], now: t0)
    let moving = announcer.announcements(
        for: [tracked(.person, id: 2, meters: 2.9, approaching: true)], now: t0
    )

    #expect(try! #require(staticOne.first).message.priority == .environmentInformation)
    #expect(try! #require(moving.first).message.priority == .immediateRisk)
}

@Test func betweenThreeAndFourMetersItSaysNearWithoutMeters() {
    var announcer = ObstacleAnnouncer()
    let output = try! #require(
        announcer.announcements(for: [tracked(.car, id: 1, meters: 3.5)], now: t0).first
    )

    #expect(output.message.text == "carro cerca")
    #expect(output.message.priority == .environmentInformation)
    #expect(!output.event.requiresImmediateAction)
}

@Test func withoutADistanceItOnlyNamesTheObject() {
    var announcer = ObstacleAnnouncer()
    let output = try! #require(
        announcer.announcements(for: [tracked(.person, id: 1, meters: nil)], now: t0).first
    )

    #expect(output.message.text == "persona")
    #expect(output.message.priority == .environmentInformation)
}

@Test func reducedModeNeverSaysMeters() {
    var announcer = ObstacleAnnouncer()
    let veryClose = try! #require(
        announcer.announcements(for: [tracked(.person, id: 1, meters: 1.0)], now: t0, mode: .reduced).first
    )
    let close = try! #require(
        announcer.announcements(for: [tracked(.person, id: 2, meters: 2.0)], now: t0, mode: .reduced).first
    )
    let beyond = try! #require(
        announcer.announcements(for: [tracked(.person, id: 3, meters: 3.0)], now: t0, mode: .reduced).first
    )

    #expect(veryClose.message.text == "persona muy cerca")
    #expect(veryClose.message.priority == .immediateRisk)
    #expect(close.message.text == "persona cerca")
    #expect(close.message.priority == .environmentInformation)
    // Más allá de 2,5 m no se promete aviso de distancia.
    #expect(beyond.message.text == "persona")
    #expect(!veryClose.message.text.contains("metros"))
    #expect(!close.message.text.contains("metros"))
}

@Test func reducedModeUsesItsOwnUrgentThreshold() {
    var announcer = ObstacleAnnouncer()
    // 2,0 m es zona de riesgo con LiDAR pero solo «cerca» sin LiDAR.
    let lidar = announcer.announcements(for: [tracked(.person, id: 1, meters: 2.0)], now: t0, mode: .lidar)
    let reduced = announcer.announcements(for: [tracked(.person, id: 2, meters: 2.0)], now: t0, mode: .reduced)

    #expect(try! #require(lidar.first).message.priority == .immediateRisk)
    #expect(try! #require(reduced.first).message.priority == .environmentInformation)
}

@Test func distanceJitterAroundTheThresholdDoesNotRepeatTheAlert() {
    var announcer = ObstacleAnnouncer()
    // Entra a la zona de riesgo (2,4 m) y avisa una vez.
    #expect(announcer.announcements(for: [tracked(.person, id: 1, meters: 2.4)], now: t0).count == 1)
    // La medición oscila alrededor de 2,5 m sin que el objeto se acerque: silencio.
    for (i, meters) in [Float(2.6), 2.4, 2.7, 2.45].enumerated() {
        let out = announcer.announcements(
            for: [tracked(.person, id: 1, meters: meters)], now: t0.addingTimeInterval(Double(i + 1) * 6)
        )
        #expect(out.isEmpty)
    }
}

@Test func anApproachingObjectDoesNotRepeatWithinTheCooldown() {
    var announcer = ObstacleAnnouncer(announcementInterval: 4.0)
    #expect(announcer.announcements(for: [tracked(.car, id: 1, meters: 2.4, approaching: true)], now: t0).count == 1)
    let early = announcer.announcements(
        for: [tracked(.car, id: 1, meters: 1.8, approaching: true)], now: t0.addingTimeInterval(2)
    )
    let late = announcer.announcements(
        for: [tracked(.car, id: 1, meters: 1.2, approaching: true)], now: t0.addingTimeInterval(4)
    )

    #expect(early.isEmpty)
    #expect(late.count == 1)
}

@Test func theAlertDoesNotNeedAnyNetworkOrBackend() {
    // La clasificación y los avisos son valores puros sin red (SCRUM-34: funciona sin conexión).
    var announcer = ObstacleAnnouncer(proximity: ProximityPolicy())
    let output = announcer.announcements(for: [tracked(.person, id: 1, meters: 1.0)], now: t0)

    #expect(output.count == 1)
    #expect(DetectionFocusConfig().proximity == ProximityPolicy())
}

@Test func deduplicationPolicyDiscardsOlderAndRepeatedCaptures() {
    var announcer = ObstacleAnnouncer()
    // Fuera de la zona de riesgo (> 3 m acercándose): son P3 y la deduplicación aplica.
    let older = try! #require(
        announcer.announcements(for: [tracked(.car, id: 1, meters: 3.8, approaching: true)], now: t0).first
    ).message
    let newer = try! #require(
        announcer.announcements(
            for: [tracked(.car, id: 1, meters: 3.5, approaching: true)], now: t0.addingTimeInterval(5)
        ).first
    ).message

    let policy = AudioDeduplicationPolicy()
    #expect(policy.isNewerCapture(newer, than: older))
    #expect(!policy.isNewerCapture(older, than: newer))
    #expect(policy.isDuplicate(older, of: newer))
    #expect(!policy.isDuplicate(newer, of: older))
}
