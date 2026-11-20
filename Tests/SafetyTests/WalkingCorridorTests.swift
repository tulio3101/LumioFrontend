import Testing
import CoreGraphics
@testable import LumioFrontend

// SCRUM-33: el corredor de marcha es la franja central-inferior donde un obstáculo está "en el
// camino". Se desplaza con la inclinación del teléfono. Valor puro, testeable sin ARKit.

private let corridor = WalkingCorridor(config: DetectionFocusConfig())  // 40% central, mitad inferior

@Test func boxInCentralLowerBandIsInCorridor() {
    let box = CGRect(x: 0.45, y: 0.6, width: 0.1, height: 0.2)
    #expect(corridor.contains(box))
}

@Test func boxOnTheSideIsOutsideCorridor() {
    let leftEdge = CGRect(x: 0.0, y: 0.6, width: 0.1, height: 0.2)   // fuera del 40% central
    #expect(!corridor.contains(leftEdge))
}

@Test func boxInUpperBandIsOutsideCorridor() {
    let upper = CGRect(x: 0.45, y: 0.1, width: 0.1, height: 0.2)     // mitad superior
    #expect(!corridor.contains(upper))
}

@Test func pitchShiftsTheCorridorDown() {
    // Apuntar más arriba (pitch +) baja la franja: su borde superior sube de valor (más abajo).
    #expect(corridor.rect(pitchDegrees: 20).minY > corridor.rect(pitchDegrees: 0).minY)

    // Una caja justo en el borde está dentro sin inclinación pero fuera al inclinar hacia arriba.
    let box = CGRect(x: 0.45, y: 0.5, width: 0.1, height: 0.1)
    #expect(corridor.contains(box, pitchDegrees: 0))
    #expect(!corridor.contains(box, pitchDegrees: 20))
}

@Test func pitchStateClassifiesTiltRange() {
    #expect(pitchState(-40, minDegrees: -35, maxDegrees: 35) == .tooLow)
    #expect(pitchState(0,   minDegrees: -35, maxDegrees: 35) == .ok)
    #expect(pitchState(40,  minDegrees: -35, maxDegrees: 35) == .tooHigh)
}
