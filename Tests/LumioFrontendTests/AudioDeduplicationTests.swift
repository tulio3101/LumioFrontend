import Foundation
import Testing
@testable import LumioFrontend

private func event(
    _ priority: AudioPriority = .environmentInformation,
    context: String? = "scene", key: String? = "event", sequence: UInt64? = nil,
    expiresAt: Date? = nil
) -> AudioMessage {
    AudioMessage(text: "Mismo texto", priority: priority, expiresAt: expiresAt,
                 contextID: context, deduplicationKey: key, captureSequence: sequence)
}

@Test @MainActor func duplicatesAreSuppressedWhileActiveAndPending() {
    for priority in [AudioPriority.routeInformation, .environmentInformation] {
        let player = FakeAudioPlayer()
        let service = AudioArbiterService(player: player)
        var discarded: [UUID] = []
        service.onMessageChanged = { if $0.status == .discarded { discarded.append($0.id) } }
        let active = event(priority)
        service.receive(active)
        service.receive(active) // UUID repetido no descarta el original.
        let duplicate = event(priority)
        service.receive(duplicate)
        #expect(discarded == [duplicate.id])
        #expect(service.currentMessage?.id == active.id)
        #expect(service.pendingMessages.isEmpty)
        player.finish()
        let later = event(priority)
        service.receive(later) // No hay historial de duplicados ya reproducidos.
        #expect(service.currentMessage?.id == later.id)

        service.receive(event(.immediateRisk))
        let pending = event(priority, key: "pending")
        service.receive(pending)
        service.receive(event(priority, key: "pending"))
        #expect(service.pendingMessages.filter { $0.deduplicationKey == "pending" }.count == 1)
    }
}

@Test @MainActor func differentContextsPrioritiesAndMissingKeysRemainValid() {
    let service = AudioArbiterService(player: FakeAudioPlayer())
    service.receive(event(.immediateRisk))
    let messages = [event(context: "A"), event(context: "B"), event(.routeInformation, context: "A"),
                    event(key: nil), event(key: nil), event(context: nil), event(context: nil)]
    for message in messages { service.receive(message) }
    #expect(service.pendingMessages.map(\.id) == messages.map(\.id))
}

@Test @MainActor func safetyAlertsBypassKeyButStaleCapturesAreDiscarded() {
    let player = FakeAudioPlayer()
    let service = AudioArbiterService(player: player)
    // (1) Sin captureSequence: una clave repetida no descarta un immediateRisk.
    let first = event(.immediateRisk, key: "danger")
    let second = event(.immediateRisk, key: "danger")
    service.receive(first)
    service.receive(first) // UUID repetido no descarta el original.
    service.receive(second)
    #expect(service.pendingMessages.map(\.id) == [second.id])
    player.finish()
    #expect(service.currentMessage?.id == second.id)
    player.finish()
    // (2) Con captureSequence (alerta de obstáculo): una captura vieja se descarta aunque sea
    // immediateRisk, mientras una más nueva se acepta (SCRUM-33).
    let fresh = event(.immediateRisk, key: "obstacle", sequence: 10)
    let stale = event(.immediateRisk, key: "obstacle", sequence: 3)
    service.receive(fresh)
    service.receive(stale)
    #expect(service.currentMessage?.id == fresh.id)
    #expect(service.pendingMessages.isEmpty)
}

@Test @MainActor func newerCaptureReplacesPendingEvenWithSameKey() {
    let player = FakeAudioPlayer()
    let service = AudioArbiterService(player: player)
    var discarded: [UUID] = []
    service.onMessageChanged = { if $0.status == .discarded { discarded.append($0.id) } }
    service.receive(event(.immediateRisk))
    let old = event(sequence: 1)
    let recent = event(sequence: 2)
    service.receive(old)
    service.receive(recent)
    #expect(discarded == [old.id])
    #expect(service.pendingMessages.map(\.id) == [recent.id])
    player.finish()
    #expect(service.currentMessage?.id == recent.id)
}

@Test @MainActor func lateCaptureIsRejectedEvenAfterRecentPlaybackFinished() {
    let player = FakeAudioPlayer()
    let service = AudioArbiterService(player: player)
    let recent = event(sequence: 5)
    service.receive(recent)
    player.finish()
    service.receive(event(key: "different", sequence: 4))
    #expect(service.currentMessage == nil)
    #expect(player.started == [recent.id])
}

@Test @MainActor func invalidNewCaptureDoesNotReplaceValidNarrationOrAdvanceWatermark() {
    let player = FakeAudioPlayer()
    let timestamp = Date()
    let service = AudioArbiterService(player: player, now: { timestamp })
    service.receive(event(.immediateRisk))
    let old = event(sequence: 1)
    service.receive(old)
    service.receive(event(sequence: 100, expiresAt: timestamp))
    #expect(service.pendingMessages.map(\.id) == [old.id])
    let valid = event(sequence: 2)
    service.receive(valid)
    #expect(service.pendingMessages.map(\.id) == [valid.id])
    service.updateContext(AudioDecisionContext(invalidatedContextIDs: ["invalid"]))
    service.receive(event(context: "invalid", sequence: 100))
    #expect(service.pendingMessages.map(\.id) == [valid.id])
}

@Test @MainActor func newCaptureDoesNotInterruptActiveNarration() {
    let player = FakeAudioPlayer()
    let service = AudioArbiterService(player: player)
    let active = event(sequence: 1)
    let recent = event(sequence: 2)
    service.receive(active)
    service.receive(recent)
    #expect(service.currentMessage?.id == active.id)
    #expect(player.stops == 0)
    #expect(service.pendingMessages.map(\.id) == [recent.id])
    player.finish()
    #expect(service.currentMessage?.id == recent.id)
}

@Test @MainActor func discardPreservesPriorityAndArrivalOrderOfSurvivors() {
    let player = FakeAudioPlayer()
    let service = AudioArbiterService(player: player)
    service.receive(event(.immediateRisk))
    let old = event(sequence: 1)
    let other = event(context: "other")
    let firstTurn = event(.routeInformation, key: "turn1")
    let secondTurn = event(.routeInformation, key: "turn2")
    let recent = event(sequence: 2)
    for message in [old, other, firstTurn, secondTurn, recent] { service.receive(message) }
    for expected in [firstTurn, secondTurn, other, recent] {
        player.finish()
        #expect(service.currentMessage?.id == expected.id)
    }
    player.finish()
    #expect(service.currentMessage == nil)
}

@Test @MainActor func expiredDuplicateDoesNotSuppressFreshMessage() {
    let player = FakeAudioPlayer()
    var timestamp = Date()
    let service = AudioArbiterService(player: player, now: { timestamp })
    service.receive(event(.immediateRisk))
    service.receive(event(expiresAt: timestamp.addingTimeInterval(1)))
    timestamp = timestamp.addingTimeInterval(2)
    let fresh = event()
    service.receive(fresh)
    #expect(service.pendingMessages.map(\.id) == [fresh.id])
}

@Test @MainActor func resetAndContextInvalidationReleaseCaptureHistory() {
    let player = FakeAudioPlayer()
    let service = AudioArbiterService(player: player)
    service.receive(event(sequence: 100))
    let oldToken = player.active!
    service.resetSession()
    let fresh = event(sequence: 1)
    service.receive(fresh)
    player.onFinished?(oldToken)
    #expect(service.currentMessage?.id == fresh.id)
    player.finish()
    service.updateContext(AudioDecisionContext(invalidatedContextIDs: ["scene"]))
    service.updateContext(AudioDecisionContext())
    let reused = event(sequence: 0)
    service.receive(reused)
    #expect(service.currentMessage?.id == reused.id)
}
