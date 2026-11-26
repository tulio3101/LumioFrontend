import Foundation
import Testing
@testable import LumioFrontend

// SCRUM-42: Gestionar Prioridad de Audios. Cada prueba corresponde a un criterio de la HU o
// a un escenario del spike de reglas de audio (SCRUM-309). Usa FakeAudioPlayer de
// AudioArbiterTests.swift.

private func message(_ priority: AudioPriority, _ text: String = "Mensaje") -> AudioMessage {
    AudioMessage(text: text, priority: priority)
}

// MARK: Clasificación

@Test func prioritiesAreOrderedFromSafetyToEnvironment() {
    #expect(AudioPriority.immediateRisk.rawValue < AudioPriority.routeInformation.rawValue)
    #expect(AudioPriority.routeInformation.rawValue < AudioPriority.environmentInformation.rawValue)
}

@Test func producersClassifyTheirMessages() {
    // Seguridad: la pérdida de la detección es una alerta P1.
    #expect(SafetyAudio.modelUnavailable().priority == .immediateRisk)
    // Navegación: las indicaciones son P2.
    let route = ActiveRoute(
        id: UUID(),
        remoteID: nil,
        origin: RoutePlace(name: "Ubicación actual", coordinate: GeoCoordinate(latitude: 4.61, longitude: -74.1)),
        destination: RoutePlace(name: "Parque", coordinate: GeoCoordinate(latitude: 4.6, longitude: -74.1)),
        steps: [RouteStep(order: 0, instruction: "Gira a la derecha", distanceMeters: 30, maneuverCoordinate: nil)],
        distanceMeters: 30,
        expectedTravelTimeSeconds: 30,
        createdAt: Date()
    )
    let builder = NavigationInstructionBuilder()
    #expect(builder.message(for: route.steps[0], in: route, now: Date()).priority == .routeInformation)
    #expect(builder.readyMessage(for: route, now: Date()).priority == .routeInformation)
    // Narración del entorno: siempre P3, aunque el backend la marque como urgente.
    let narration = NarrationAudio.message(text: "Hay una puerta a tu izquierda.", capturedAt: Date(), captureSequence: 1)
    #expect(narration.priority == .environmentInformation)
    #expect(narration.contextID == NarrationAudio.contextID)
}

// MARK: Escenarios del spike

@Test @MainActor func safetyAlertPlaysFirstWhenArrivingWithNavigation() {
    // Escenario 11: P1 y P2 llegan juntos; suena primero P1 aunque llegó después.
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player)
    let narration = message(.environmentInformation)
    arbiter.receive(narration)
    let turn = message(.routeInformation)
    let risk = message(.immediateRisk)
    arbiter.receive(turn)
    arbiter.receive(risk)
    #expect(arbiter.currentMessage?.id == risk.id)
    player.finish()
    #expect(arbiter.currentMessage?.id == turn.id)
}

@Test @MainActor func safetyAlertInterruptsNavigationWhichThenRestarts() {
    // Escenarios 3 y 10: P1 interrumpe una indicación P2; la indicación vuelve después.
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player)
    let turn = message(.routeInformation)
    arbiter.receive(turn)
    arbiter.receive(message(.immediateRisk))
    #expect(arbiter.currentMessage?.priority == .immediateRisk)
    #expect(player.stops == 1)
    player.finish()
    #expect(arbiter.currentMessage?.id == turn.id)
    #expect(player.started.filter { $0 == turn.id }.count == 2)
}

@Test @MainActor func safetyAlertIsNeverInterruptedByAnotherPriority() {
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player)
    let risk = message(.immediateRisk)
    arbiter.receive(risk)
    arbiter.receive(message(.routeInformation))
    arbiter.receive(message(.environmentInformation))
    arbiter.updateContext(AudioDecisionContext(urgentNavigationMessageIDs: Set(arbiter.pendingMessages.map(\.id))))
    #expect(arbiter.currentMessage?.id == risk.id)
    #expect(player.stops == 0)
}

@Test @MainActor func navigationGoesBeforeNarrationInTheQueue() {
    // Criterio: las instrucciones de navegación tienen prioridad sobre la narración.
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player)
    arbiter.receive(message(.immediateRisk))
    let narration = NarrationAudio.message(text: "Escena", capturedAt: Date(), captureSequence: 1)
    arbiter.receive(narration)
    let turn = message(.routeInformation)
    arbiter.receive(turn)
    player.finish()
    #expect(arbiter.currentMessage?.id == turn.id)
    player.finish()
    #expect(arbiter.currentMessage?.id == narration.id)
}

@Test @MainActor func narrationOnlyPlaysWhenTheChannelIsFree() {
    // Escenarios 6, 7 y "P3 durante P2/P1": la narración espera y no interrumpe a nadie.
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player)
    let turn = message(.routeInformation)
    arbiter.receive(turn)
    let narration = NarrationAudio.message(text: "Escena", capturedAt: Date(), captureSequence: 1)
    arbiter.receive(narration)
    #expect(arbiter.currentMessage?.id == turn.id)
    #expect(arbiter.pendingMessages.map(\.id) == [narration.id])
    #expect(player.stops == 0)
    player.finish()
    #expect(arbiter.currentMessage?.id == narration.id)
    // Otra narración tampoco interrumpe a la que suena.
    arbiter.receive(NarrationAudio.message(text: "Otra escena", capturedAt: Date(), captureSequence: 2))
    #expect(arbiter.currentMessage?.id == narration.id)
    #expect(player.stops == 0)
}

@Test @MainActor func safetyAlertDiscardsNarrationWithoutResumingIt() {
    // Escenarios 2, 8 y 9: P1 interrumpe la narración, que se descarta y no se reanuda.
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player)
    var discarded: [UUID] = []
    arbiter.onMessageChanged = { if $0.status == .discarded { discarded.append($0.id) } }
    let narration = NarrationAudio.message(text: "Escena", capturedAt: Date(), captureSequence: 1)
    arbiter.receive(narration)
    arbiter.receive(message(.immediateRisk))
    #expect(discarded == [narration.id])
    player.finish()
    #expect(arbiter.currentMessage == nil)
    #expect(player.started.filter { $0 == narration.id }.count == 1)
}

@Test @MainActor func staleNarrationIsDroppedBeforeItsTurn() {
    // Una narración que esperó demasiado ya no describe lo que hay delante.
    let player = FakeAudioPlayer()
    var now = Date(timeIntervalSince1970: 1_000)
    let arbiter = AudioArbiterService(player: player, now: { now })
    arbiter.receive(message(.routeInformation))
    arbiter.receive(NarrationAudio.message(text: "Escena", capturedAt: now, captureSequence: 1))
    now = now.addingTimeInterval(NarrationAudio.defaultLifetime)
    player.finish()
    #expect(arbiter.currentMessage == nil)
    #expect(arbiter.pendingMessages.isEmpty)
}

@Test @MainActor func newerNarrationReplacesAPendingOlderOne() {
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player)
    arbiter.receive(message(.routeInformation))
    let old = NarrationAudio.message(text: "Vieja", capturedAt: Date(), captureSequence: 1)
    let new = NarrationAudio.message(text: "Nueva", capturedAt: Date(), captureSequence: 2)
    arbiter.receive(old)
    arbiter.receive(new)
    #expect(arbiter.pendingMessages.map(\.id) == [new.id])
}

// MARK: Ningún módulo reproduce audio fuera del árbitro

/// APIs que producen sonido. Solo el reproductor del árbitro puede usarlas.
private let playbackAPIs = [
    "AVSpeechSynthesizer", "AVSpeechUtterance", "AVAudioPlayer", "AVPlayer(",
    "AVQueuePlayer", "AudioServicesPlaySystemSound", "AudioServicesPlayAlertSound",
    "SystemSoundID", "AVAudioPlayerNode",
]

private let arbiterPlayerFile = "Features/Audio/Data/SpeechAudioPlayer.swift"

private func sourceFiles() throws -> [(path: String, text: String)] {
    // Tests/LumioFrontendTests/AudioPriorityTests.swift -> Sources/LumioFrontend
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LumioFrontend", isDirectory: true)
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    var files: [(String, String)] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        let relative = String(url.path.dropFirst(root.path.count + 1))
        // Solo código: los comentarios pueden nombrar las APIs sin usarlas.
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        files.append((relative, code))
    }
    return files
}

@Test func onlyTheArbiterPlayerUsesPlaybackAPIs() throws {
    let files = try sourceFiles()
    #expect(files.count > 50, "No se encontraron los fuentes de la app")
    var offenders: [String] = []
    for file in files where file.path != arbiterPlayerFile {
        for api in playbackAPIs where file.text.contains(api) {
            offenders.append("\(file.path): \(api)")
        }
    }
    #expect(offenders.isEmpty, "Reproducen audio sin pasar por el AudioArbiter: \(offenders)")
}

@Test func theArbiterPlayerIsOnlyCreatedAtTheCompositionRoot() throws {
    let creators = try sourceFiles()
        .filter { $0.text.contains("SpeechAudioPlayer()") }
        .map(\.path)
    #expect(creators == ["App/AppDependencies.swift"])
}
