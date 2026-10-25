import Foundation
import Testing
@testable import LumioFrontend

@MainActor
private final class FakeAudioPlayer: AudioPlaying {
    var onFinished: ((PlaybackToken) -> Void)?
    var active: PlaybackToken?
    var started: [UUID] = []
    var stops = 0
    var failNext = false

    func play(_ message: AudioMessage, token: PlaybackToken) throws {
        #expect(active == nil, "Nunca deben sonar dos mensajes simultáneamente")
        if failNext {
            failNext = false
            throw Failure.start
        }
        active = token
        started.append(message.id)
    }

    func stop() {
        let old = active
        active = nil
        stops += 1
        if let old { onFinished?(old) } // Cancelación síncrona también debe ignorarse.
    }

    func finish() {
        guard let token = active else { return }
        active = nil
        onFinished?(token)
    }

    enum Failure: Error { case start }
}

private func message(_ priority: AudioPriority, contextID: String? = nil) -> AudioMessage {
    AudioMessage(text: "Mensaje", priority: priority, contextID: contextID)
}

@Test @MainActor func priorityAndFIFOWhileReceiving() {
    let player = FakeAudioPlayer()
    let service = AudioArbiterService(player: player)
    let risk = message(.immediateRisk)
    let narration = message(.environmentInformation)
    let first = message(.routeInformation)
    let second = message(.routeInformation)
    for item in [risk, narration, first, second] { service.receive(item) }
    #expect(service.currentMessage?.id == risk.id)
    for expected in [first, second, narration] {
        player.finish()
        #expect(service.currentMessage?.id == expected.id)
    }
    player.finish()
    #expect(service.currentMessage == nil)
    #expect(service.pendingMessages.isEmpty)
}

@Test @MainActor func riskDiscardsNarrationAndIgnoresOldCallback() {
    let player = FakeAudioPlayer()
    let service = AudioArbiterService(player: player)
    var discarded: [UUID] = []
    service.onMessageChanged = { if $0.status == .discarded { discarded.append($0.id) } }
    let narration = message(.environmentInformation)
    let risk = message(.immediateRisk)
    service.receive(narration)
    let old = player.active!
    service.receive(risk)
    #expect(player.stops == 1)
    #expect(discarded == [narration.id])
    player.onFinished?(old)
    #expect(service.currentMessage?.id == risk.id)
    player.finish()
    #expect(service.currentMessage == nil)
}

@Test @MainActor func navigationWaitsUntilItsOwnUrgencyChanges() {
    let player = FakeAudioPlayer()
    let service = AudioArbiterService(player: player)
    let narration = message(.environmentInformation)
    let turn = message(.routeInformation)
    service.receive(narration)
    service.receive(turn)
    #expect(service.currentMessage?.id == narration.id)
    service.updateContext(AudioDecisionContext(urgentNavigationMessageIDs: [UUID()]))
    #expect(service.currentMessage?.id == narration.id)
    service.updateContext(AudioDecisionContext(urgentNavigationMessageIDs: [turn.id]))
    #expect(service.currentMessage?.id == turn.id)
    #expect(player.stops == 1)
}

@Test @MainActor func interruptedNavigationRestartsWithANewToken() {
    let player = FakeAudioPlayer()
    let service = AudioArbiterService(player: player)
    let turn = message(.routeInformation)
    let later = message(.routeInformation)
    service.receive(turn)
    let old = player.active!
    service.receive(later)
    service.receive(message(.immediateRisk))
    player.finish()
    #expect(service.currentMessage?.id == turn.id)
    #expect(player.active != old)
    player.onFinished?(old)
    #expect(service.currentMessage?.id == turn.id)
    player.finish()
    #expect(service.currentMessage?.id == later.id)
}

@Test @MainActor func contextInvalidatesInterruptedNavigation() {
    let player = FakeAudioPlayer()
    let service = AudioArbiterService(player: player)
    let turn = message(.routeInformation, contextID: "turn-1")
    service.receive(turn)
    service.receive(message(.immediateRisk))
    service.updateContext(AudioDecisionContext(invalidatedContextIDs: ["turn-1"]))
    player.finish()
    #expect(service.currentMessage == nil)
    #expect(player.started.count == 2)
}

@Test @MainActor func expirationIsRecheckedBeforePlayback() {
    let player = FakeAudioPlayer()
    var now = Date(timeIntervalSince1970: 100)
    let service = AudioArbiterService(player: player, now: { now })
    service.receive(message(.immediateRisk))
    service.receive(AudioMessage(text: "Giro", priority: .routeInformation,
                                 expiresAt: now.addingTimeInterval(1)))
    now = now.addingTimeInterval(1)
    player.finish()
    #expect(service.currentMessage == nil)
    #expect(service.pendingMessages.isEmpty)
}

@Test @MainActor func duplicatesAndInvalidMessagesDoNotEnterQueue() {
    let player = FakeAudioPlayer()
    let now = Date()
    let service = AudioArbiterService(player: player, now: { now })
    let active = message(.immediateRisk)
    let pending = message(.routeInformation)
    for item in [active, active, pending, pending] { service.receive(item) }
    service.receive(AudioMessage(text: "Vencido", priority: .immediateRisk, expiresAt: now))
    var completed = message(.immediateRisk)
    completed.status = .completed
    service.receive(completed)
    #expect(player.started == [active.id])
    #expect(service.pendingMessages.map(\.id) == [pending.id])
}

@Test @MainActor func playbackFailureDoesNotBlockFollowingMessages() {
    let player = FakeAudioPlayer()
    let service = AudioArbiterService(player: player)
    var failures = 0
    service.onPlaybackError = { _, _ in failures += 1 }
    service.receive(message(.immediateRisk))
    service.receive(message(.routeInformation))
    let last = message(.environmentInformation)
    service.receive(last)
    player.failNext = true
    player.finish()
    #expect(failures == 1)
    #expect(service.currentMessage?.id == last.id)
}

@Test @MainActor func equalPriorityDoesNotInterruptAndIdleOperationsAreSafe() {
    let player = FakeAudioPlayer()
    let service = AudioArbiterService(player: player)
    service.processNext()
    service.discardIrrelevant()
    service.playbackFinished(token: PlaybackToken())
    for priority in AudioPriority.allCases {
        let first = message(priority)
        let second = message(priority)
        service.receive(first)
        service.receive(second)
        #expect(service.currentMessage?.id == first.id)
        player.finish()
        #expect(service.currentMessage?.id == second.id)
        player.finish()
    }
    #expect(player.stops == 0)
}
