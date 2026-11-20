import Testing
import CoreGraphics
@testable import LumioFrontend

// SCRUM-33: el tracker asigna IDs estables por IoU, exige persistencia (N de M) antes de emitir
// y olvida un objeto tras K frames sin verse. Solo considera objetos del corredor de marcha.

private func det(_ cls: ObstacleClass, _ box: CGRect, meters: Float? = nil) -> Detection {
    Detection(obstacleClass: cls, confidence: 0.9, boundingBox: box, distanceMeters: meters)
}

// Caja dentro del corredor (central-inferior).
private let boxA = CGRect(x: 0.45, y: 0.60, width: 0.10, height: 0.20)
private let boxB = CGRect(x: 0.60, y: 0.60, width: 0.08, height: 0.10)  // no solapa A

@Test func requiresPersistenceBeforeEmitting() {
    var tracker = ObstacleTracker()  // minAppearances 3 de 5 por defecto
    #expect(tracker.update([det(.chair, boxA)]).isEmpty)   // aparición 1
    #expect(tracker.update([det(.chair, boxA)]).isEmpty)   // aparición 2
    #expect(tracker.update([det(.chair, boxA)]).count == 1) // aparición 3 → emite
}

@Test func keepsStableIdAcrossFrames() {
    var tracker = ObstacleTracker()
    for _ in 0..<2 { _ = tracker.update([det(.chair, boxA)]) }
    let id3 = try! #require(tracker.update([det(.chair, boxA)]).first).id
    let id4 = try! #require(tracker.update([det(.chair, boxA)]).first).id
    #expect(id3 == id4)
}

@Test func distinctObjectsGetDistinctIds() {
    var tracker = ObstacleTracker()
    var out: [TrackedDetection] = []
    for _ in 0..<3 { out = tracker.update([det(.chair, boxA), det(.chair, boxB)]) }
    #expect(out.count == 2)
    #expect(Set(out.map(\.id)).count == 2)   // dos IDs diferentes
}

@Test func objectsOutsideCorridorAreIgnored() {
    var tracker = ObstacleTracker()
    let side = CGRect(x: 0.0, y: 0.6, width: 0.1, height: 0.2)   // pegada al borde: fuera del corredor
    for _ in 0..<4 { _ = tracker.update([det(.person, side)]) }
    #expect(tracker.update([det(.person, side)]).isEmpty)
}

@Test func forgetsObjectAfterMissedFrames() {
    var tracker = ObstacleTracker()   // maxMissedFrames 5 por defecto
    for _ in 0..<2 { _ = tracker.update([det(.chair, boxA)]) }
    let firstId = try! #require(tracker.update([det(.chair, boxA)]).first).id

    // Hueco mayor que maxMissedFrames → se olvida.
    for _ in 0..<6 { _ = tracker.update([]) }

    // Reaparece: nuevo track, nuevo ID (prueba que se olvidó).
    for _ in 0..<2 { _ = tracker.update([det(.chair, boxA)]) }
    let newId = try! #require(tracker.update([det(.chair, boxA)]).first).id
    #expect(newId != firstId)
}
