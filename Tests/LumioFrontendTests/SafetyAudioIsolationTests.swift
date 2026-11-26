import Foundation
import Testing
@testable import LumioFrontend

@MainActor
private final class IsolationPlayer: AudioPlaying {
    var onFinished: ((PlaybackToken) -> Void)?
    var texts: [String] = []
    var currentToken: PlaybackToken?
    func play(_ message: AudioMessage, token: PlaybackToken) throws {
        texts.append(message.text)
        currentToken = token
    }
    func stop() { currentToken = nil }
}

// SCRUM-37: detener o perder la detección retira solo el contexto "safety"; la navegación
// interrumpida vuelve a sonar y la narración sigue en cola.
@Test @MainActor func retiringSafetyAudioKeepsNavigationAndNarration() {
    let player = IsolationPlayer()
    let arbiter = AudioArbiterService(player: player)
    arbiter.receive(AudioMessage(text: "Gira", priority: .routeInformation, contextID: "route"))
    arbiter.receive(AudioMessage(text: "Persona", priority: .immediateRisk, contextID: "safety"))
    arbiter.receive(AudioMessage(text: "Escena", priority: .environmentInformation, contextID: "narration"))
    arbiter.cancel(contextIDs: [SafetyAudio.context])
    #expect(arbiter.currentMessage?.text == "Gira")
    #expect(arbiter.pendingMessages.map(\.text) == ["Escena"])
    #expect(player.texts == ["Gira", "Persona", "Gira"])
}
