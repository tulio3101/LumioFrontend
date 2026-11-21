import Foundation

/// La voz habla por el AudioArbiter (ningún módulo reproduce audio por su cuenta).
/// P2 con contexto propio: una alerta P1 la interrumpe y no se confunde con la navegación.
@MainActor
final class ArbiterVoiceAudio: VoiceAudioOutput {
    static let context = "voice-command"
    private let arbiter: AudioArbiterService

    init(arbiter: AudioArbiterService) {
        self.arbiter = arbiter
    }

    func say(_ text: String) async {
        _ = await arbiter.receiveAndWait(message(text))
    }

    func announce(_ text: String) {
        arbiter.receive(message(text))
    }

    var isPlayingCriticalAlert: Bool {
        arbiter.currentMessage?.priority == .immediateRisk
    }

    private func message(_ text: String) -> AudioMessage {
        AudioMessage(
            text: text,
            priority: .routeInformation,
            // Una respuesta que se retrasa demasiado tras otras alertas ya no sirve.
            expiresAt: Date().addingTimeInterval(30),
            contextID: Self.context
        )
    }
}
