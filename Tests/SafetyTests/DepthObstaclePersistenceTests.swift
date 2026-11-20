import Testing
import Foundation
@testable import LumioFrontend

// SCRUM-33 (ajuste): los obstáculos por profundidad pasan por persistencia N-de-M + cooldown, igual
// que las cajas YOLO. Un frame ruidoso aislado no alerta; el mismo tipo no se repite en el cooldown.

private let t0 = Date(timeIntervalSince1970: 1_000)

@Test func requiresNofMBeforeAnnouncing() {
    var gate = PersistenceGate(minAppearances: 3, windowFrames: 5, cooldown: 4)
    #expect(gate.update(present: ["wall"], now: t0).isEmpty)                       // 1
    #expect(gate.update(present: ["wall"], now: t0.addingTimeInterval(0.1)).isEmpty) // 2
    #expect(gate.update(present: ["wall"], now: t0.addingTimeInterval(0.2)) == ["wall"]) // 3 → anuncia
}

@Test func isolatedNoisyFrameDoesNotAnnounce() {
    var gate = PersistenceGate(minAppearances: 3, windowFrames: 5, cooldown: 4)
    // Un único frame con "wall" rodeado de frames vacíos → nunca alcanza 3 de 5.
    var announced = false
    announced = announced || !gate.update(present: [], now: t0).isEmpty
    announced = announced || !gate.update(present: ["wall"], now: t0.addingTimeInterval(0.1)).isEmpty
    announced = announced || !gate.update(present: [], now: t0.addingTimeInterval(0.2)).isEmpty
    announced = announced || !gate.update(present: [], now: t0.addingTimeInterval(0.3)).isEmpty
    announced = announced || !gate.update(present: [], now: t0.addingTimeInterval(0.4)).isEmpty
    #expect(!announced)
}

@Test func cooldownSuppressesRepeatOfSameType() {
    var gate = PersistenceGate(minAppearances: 3, windowFrames: 5, cooldown: 4)
    for i in 0..<3 { _ = gate.update(present: ["wall"], now: t0.addingTimeInterval(Double(i) * 0.1)) }
    // Ya anunció en el 3.º frame. Dentro del cooldown no repite...
    #expect(gate.update(present: ["wall"], now: t0.addingTimeInterval(1)).isEmpty)
    // ...pero sí tras vencer el cooldown.
    #expect(gate.update(present: ["wall"], now: t0.addingTimeInterval(6)) == ["wall"])
}

@Test func independentKeysTrackedSeparately() {
    var gate = PersistenceGate(minAppearances: 2, windowFrames: 5, cooldown: 4)
    _ = gate.update(present: ["wall", "door"], now: t0)
    let announced = gate.update(present: ["wall", "door"], now: t0.addingTimeInterval(0.1))
    #expect(announced == Set(["wall", "door"]))
}
