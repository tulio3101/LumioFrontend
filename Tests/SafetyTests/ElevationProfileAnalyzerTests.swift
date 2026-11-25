import Testing
import Foundation
@testable import LumioFrontend

// SCRUM-33: detección de desniveles. Perfiles sintéticos (valor puro, portable). Reglas: la bajada
// es lo más crítico y solo se confirma con piso válido antes; subidas > stepMax no son escalón
// (pared); huecos aislados/sin piso antes no se interpretan como bajada.

private let cfg = DetectionFocusConfig()   // stepMin 0.08, stepMax 0.25, minFloorSamplesBeforeDrop 3, minHoleRun 2
private let analyzer = ElevationProfileAnalyzer()

/// Perfil con alturas (nil = hueco) separadas 0.25 m desde 0.5 m adelante.
private func profile(_ heights: [Float?], near: Float = 0.5, step: Float = 0.25) -> ElevationProfile {
    ElevationProfile(samples: heights.enumerated().map { i, h in
        ElevationSample(forwardMeters: near + Float(i) * step, heightAboveFloor: h)
    })
}

@Test func steppedDescentIsStairsDown() {
    if case .stairsDown = analyzer.analyze(profile([0, 0, 0, -0.17, -0.34, -0.51]), config: cfg) {} else {
        Issue.record("esperaba stairsDown")
    }
}

@Test func singleMeasuredDropIsStepDownOrCurb() {
    if case .stepDownOrCurb = analyzer.analyze(profile([0, 0, 0, -0.15, -0.15, -0.15]), config: cfg) {} else {
        Issue.record("esperaba stepDownOrCurb")
    }
}

@Test func persistentHoleWithFloorBeforeIsConservativeCurb() {
    if case .stepDownOrCurb = analyzer.analyze(profile([0, 0, 0, nil, nil, nil]), config: cfg) {} else {
        Issue.record("esperaba stepDownOrCurb conservador")
    }
}

@Test func isolatedHoleDoesNotInventADrop() {
    #expect(analyzer.analyze(profile([0, 0, nil, 0, 0]), config: cfg) == .flat)
}

@Test func dropWithoutValidFloorBeforeIsIgnored() {
    // Empieza ya bajando, sin piso de referencia → no se inventa bajada.
    #expect(analyzer.analyze(profile([-0.2, -0.4, -0.6, -0.8]), config: cfg) == .flat)
}

@Test func allHolesWithoutFloorIsFlat() {
    // Piso desactualizado / sin datos confiables → no se inventa desnivel.
    #expect(analyzer.analyze(profile([nil, nil, nil, nil]), config: cfg) == .flat)
}

@Test func repeatedRisesWithTreadsAreStairsUp() {
    // Cada peldaño sube y mantiene una huella plana antes del siguiente.
    if case .stairsUp = analyzer.analyze(profile([0, 0, 0.17, 0.17, 0.34, 0.34]), config: cfg) {} else {
        Issue.record("esperaba stairsUp")
    }
}

@Test func singleRiseWithTreadIsStepUp() {
    if case .stepUp = analyzer.analyze(profile([0, 0, 0, 0.15, 0.15, 0.15]), config: cfg) {} else {
        Issue.record("esperaba stepUp")
    }
}

// SCRUM-33 corrección 3: un zócalo/base de pared (subida sin huella plana después) NO es escalón.
@Test func baseboardRiseWithoutTreadIsFlat() {
    #expect(analyzer.analyze(profile([0, 0, 0, 0, 0.12]), config: cfg) == .flat)
}

// SCRUM-33 corrección 4: una escalera de bajada que arranca en el borde (sin piso visible antes)
// se detecta gracias al piso conocido (plano bajo los pies).
@Test func descendingStairsFromEdgeWithKnownFloor() {
    let hazard = analyzer.analyze(profile([-0.17, -0.34, -0.51]), config: cfg, hasKnownFloor: true)
    if case .stairsDown = hazard {} else { Issue.record("esperaba stairsDown desde el borde") }
}

@Test func wallAheadIsNotStairsUp() {
    // Una subida mayor que stepMax (0.25) es pared, no escalón → la maneja DepthObstacleDetector.
    #expect(analyzer.analyze(profile([0, 0, 0, 0.8, 1.2, 1.2]), config: cfg) == .flat)
}

@Test func gentleSlopeUpIsRamp() {
    if case .rampUp = analyzer.analyze(profile([0, 0.03, 0.06, 0.09, 0.12, 0.15]), config: cfg) {} else {
        Issue.record("esperaba rampUp")
    }
}

@Test func gentleSlopeDownIsRamp() {
    if case .rampDown = analyzer.analyze(profile([0, -0.03, -0.06, -0.09, -0.12, -0.15]), config: cfg) {} else {
        Issue.record("esperaba rampDown")
    }
}

@Test func flatFloorIsFlat() {
    #expect(analyzer.analyze(profile([0, 0, 0, 0, 0]), config: cfg) == .flat)
}

@Test func descentWinsOverAscentWhenBothPresent() {
    // Dos caídas y una subida → gana la bajada (prioridad).
    if case .stairsDown = analyzer.analyze(profile([0, 0, 0, -0.17, -0.34, -0.17]), config: cfg) {} else {
        Issue.record("esperaba stairsDown (bajada > subida)")
    }
}

// MARK: - Audio + announcer

@Test func downwardHazardsAreImmediateRiskAndDanger() {
    let a = ElevationAudio.announcement(for: .stairsDown(distance: 2))
    #expect(a?.priority == .immediateRisk)
    #expect(a?.isDanger == true)
    #expect(a?.typeKey == "stairs-down")
    #expect(a?.text == "escalera hacia abajo, a 2,0 metros")
}

@Test func rampIsEnvironmentInfoAndNotDanger() {
    let a = ElevationAudio.announcement(for: .rampUp(distance: 1.5))
    #expect(a?.priority == .environmentInformation)
    #expect(a?.isDanger == false)
}

@Test func flatHasNoAnnouncement() {
    #expect(ElevationAudio.announcement(for: .flat) == nil)
}

@Test func announcerBuildsElevationMessage() {
    let announcer = ObstacleAnnouncer()
    let out = announcer.elevationOutput(for: .stepDownOrCurb(distance: 1), now: Date())
    #expect(out?.message.priority == .immediateRisk)
    #expect(out?.message.deduplicationKey == "elevation-step-down")
    #expect(out?.message.text == "escalón hacia abajo, a 1,0 metros")
    #expect(out?.event.requiresImmediateAction == true)
    // flat → sin mensaje
    #expect(announcer.elevationOutput(for: .flat, now: Date()) == nil)
}
