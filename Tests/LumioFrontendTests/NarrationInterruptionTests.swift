import Foundation
import Testing
@testable import LumioFrontend

// SCRUM-44: Interrumpir Narración ante Eventos Prioritarios (reglas del spike SCRUM-309).

@MainActor
private final class TransitionPlayer: AudioPlaying {
    var onFinished: ((PlaybackToken) -> Void)?
    var active: PlaybackToken?
    var started: [(id: UUID, transition: AudioTransition)] = []
    var stops = 0

    func play(_ message: AudioMessage, token: PlaybackToken) throws {
        try play(message, token: token, transition: .immediate)
    }

    func play(_ message: AudioMessage, token: PlaybackToken, transition: AudioTransition) throws {
        #expect(active == nil, "Nunca deben sonar dos mensajes simultáneamente")
        active = token
        started.append((message.id, transition))
    }

    func stop() {
        let old = active
        active = nil
        stops += 1
        if let old { onFinished?(old) }
    }

    func finish() {
        guard let token = active else { return }
        active = nil
        onFinished?(token)
    }
}

@MainActor
private final class Harness {
    let player = TransitionPlayer()
    var now = Date(timeIntervalSince1970: 10_000)
    var scheduled: [(delay: TimeInterval, action: @MainActor () -> Void)] = []
    var discarded: [UUID] = []
    lazy var arbiter: AudioArbiterService = {
        let arbiter = AudioArbiterService(
            player: player,
            now: { [unowned self] in self.now },
            schedule: { [unowned self] delay, action in self.scheduled.append((delay, action)) }
        )
        arbiter.onMessageChanged = { [unowned self] in
            if $0.status == .discarded { self.discarded.append($0.id) }
        }
        return arbiter
    }()

    /// Narración que dura `seconds` según la estimación del árbitro.
    func narration(lasting seconds: TimeInterval, sequence: UInt64 = 1) -> AudioMessage {
        let characters = Int(seconds * SpeechDurationEstimator().charactersPerSecond)
        return NarrationAudio.message(
            text: String(repeating: "a", count: characters), capturedAt: now, captureSequence: sequence
        )
    }

    func turn(in seconds: TimeInterval, _ geometry: TurnGeometry) -> AudioMessage {
        AudioMessage(
            text: "Gira a la derecha.", priority: .routeInformation, createdAt: now,
            contextID: "route-1", deduplicationKey: "step-1",
            turnDeadline: TurnDeadline(maneuverAt: now.addingTimeInterval(seconds), geometry: geometry)
        )
    }

    func runScheduled() {
        let pending = scheduled
        scheduled = []
        for item in pending { item.action() }
    }
}

// MARK: Reglas del spike

@Test(arguments: [TurnGeometry.sharp, .wide])
func reactionTimesFollowTheSpike(geometry: TurnGeometry) {
    #expect(geometry.reactionTime == (geometry == .sharp ? 1.5 : 2.5))
}

@Test func deadlineFromDistanceAndSpeed() {
    let now = Date(timeIntervalSince1970: 0)
    let walking = TurnDeadline(distanceMeters: 12, speedMetersPerSecond: 1.2, geometry: .sharp, now: now)
    #expect(walking.maneuverAt == now.addingTimeInterval(10))
    #expect(walking.latestStart == now.addingTimeInterval(8.5))
    // Quieto o sin velocidad: se usa la marcha típica.
    let still = TurnDeadline(distanceMeters: 5, speedMetersPerSecond: 0, geometry: .wide, now: now)
    #expect(still.maneuverAt == now.addingTimeInterval(5 / TurnDeadline.typicalWalkingSpeed))
}

@Test @MainActor func safetyAlertAlwaysInterruptsNarrationImmediately() {
    let h = Harness()
    let narration = h.narration(lasting: 6)
    h.arbiter.receive(narration)
    let risk = AudioMessage(text: "Cuidado, poste delante.", priority: .immediateRisk)
    h.arbiter.receive(risk)
    #expect(h.arbiter.currentMessage?.id == risk.id)
    #expect(h.discarded == [narration.id])
    // P1 nunca espera la pausa de transición.
    #expect(h.player.started.last?.transition == .immediate)
}

@Test @MainActor func turnWaitsWhenThereIsTimeAfterTheNarration() {
    let h = Harness()
    let narration = h.narration(lasting: 3)
    h.arbiter.receive(narration)
    // Al terminar la narración quedan 7 s para el giro: espera.
    let turn = h.turn(in: 10, .sharp)
    h.arbiter.receive(turn)
    #expect(h.arbiter.currentMessage?.id == narration.id)
    #expect(h.player.stops == 0)
    h.player.finish()
    #expect(h.arbiter.currentMessage?.id == turn.id)
    #expect(h.player.started.last?.transition == .immediate)
}

@Test @MainActor func turnInterruptsWhenWaitingWouldMakeItLate() {
    let h = Harness()
    let narration = h.narration(lasting: 4)
    h.arbiter.receive(narration)
    // Esperar 4 s dejaría el giro atrás: interrumpe y descarta la narración.
    let turn = h.turn(in: 3, .sharp)
    h.arbiter.receive(turn)
    #expect(h.arbiter.currentMessage?.id == turn.id)
    #expect(h.discarded == [narration.id])
    #expect(h.player.started.last?.transition == .afterInterruption)
    // La narración no se reanuda al terminar la indicación.
    h.player.finish()
    #expect(h.arbiter.currentMessage == nil)
    #expect(h.player.started.filter { $0.id == narration.id }.count == 1)
}

@Test @MainActor func wideTurnsNeedMoreAnticipationThanSharpOnes() {
    // Tras la narración quedarían 2 s: alcanza para un giro cerrado (1,5 s), no para uno amplio (2,5 s).
    for (geometry, interrupts) in [(TurnGeometry.sharp, false), (.wide, true)] {
        let h = Harness()
        let narration = h.narration(lasting: 3)
        h.arbiter.receive(narration)
        let turn = h.turn(in: 5, geometry)
        h.arbiter.receive(turn)
        #expect((h.arbiter.currentMessage?.id == turn.id) == interrupts, "\(geometry)")
    }
}

@Test @MainActor func thresholdIsInclusive() {
    let h = Harness()
    h.arbiter.receive(h.narration(lasting: 2))
    // Quedarían exactamente 1,5 s: ya no alcanza.
    let turn = h.turn(in: 3.5, .sharp)
    h.arbiter.receive(turn)
    #expect(h.arbiter.currentMessage?.id == turn.id)
}

@Test @MainActor func elapsedNarrationTimeCountsTowardsTheWait() {
    let h = Harness()
    let narration = h.narration(lasting: 6)
    h.arbiter.receive(narration)
    h.now = h.now.addingTimeInterval(5)
    // Le falta 1 s a la narración; el giro está a 4 s: quedan 3 s, espera.
    let turn = h.turn(in: 4, .sharp)
    h.arbiter.receive(turn)
    #expect(h.arbiter.currentMessage?.id == narration.id)
}

@Test @MainActor func turnBecomesUrgentWhileANarrationRunsLongerThanEstimated() {
    let h = Harness()
    let narration = h.narration(lasting: 2)
    h.arbiter.receive(narration)
    let turn = h.turn(in: 8, .sharp)
    h.arbiter.receive(turn)
    #expect(h.arbiter.currentMessage?.id == narration.id)
    // Se programa una revisión para el último momento útil (8 − 1,5 s).
    #expect(h.scheduled.map(\.delay) == [6.5])
    // La voz va más lenta de lo estimado: a los 6,5 s todavía suena.
    h.now = h.now.addingTimeInterval(6.5)
    h.runScheduled()
    #expect(h.arbiter.currentMessage?.id == turn.id)
    #expect(h.discarded == [narration.id])
}

@Test @MainActor func scheduledCheckIsHarmlessIfTheNarrationAlreadyEnded() {
    let h = Harness()
    h.arbiter.receive(h.narration(lasting: 2))
    let turn = h.turn(in: 8, .sharp)
    h.arbiter.receive(turn)
    h.player.finish()
    #expect(h.arbiter.currentMessage?.id == turn.id)
    h.now = h.now.addingTimeInterval(6.5)
    h.runScheduled()
    #expect(h.arbiter.currentMessage?.id == turn.id)
    #expect(h.player.stops == 0)
}

@Test @MainActor func urgentTurnDoesNotInterruptOtherNavigationOrAlerts() {
    let h = Harness()
    let instruction = AudioMessage(text: "Sigue recto 50 metros.", priority: .routeInformation)
    h.arbiter.receive(instruction)
    h.arbiter.receive(h.turn(in: 0.5, .sharp))
    #expect(h.arbiter.currentMessage?.id == instruction.id)
    h.player.finish()
    let risk = AudioMessage(text: "Cuidado.", priority: .immediateRisk)
    h.arbiter.receive(risk)
    h.arbiter.receive(h.turn(in: 0.5, .wide))
    #expect(h.arbiter.currentMessage?.id == risk.id)
}

@Test @MainActor func turnWithoutDeadlineKeepsWaitingForTheProducerMark() {
    // Sin `turnDeadline` vale la marca explícita del productor (AudioDecisionContext).
    let h = Harness()
    let narration = h.narration(lasting: 4)
    h.arbiter.receive(narration)
    let turn = AudioMessage(text: "Gira.", priority: .routeInformation)
    h.arbiter.receive(turn)
    #expect(h.arbiter.currentMessage?.id == narration.id)
    h.arbiter.updateContext(AudioDecisionContext(urgentNavigationMessageIDs: [turn.id]))
    #expect(h.arbiter.currentMessage?.id == turn.id)
    #expect(h.player.started.last?.transition == .afterInterruption)
}
