#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Solo el árbitro debe usar esta instancia. No bloquea mientras habla.
@MainActor
final class SpeechAudioPlayer: NSObject, AudioPlaying, AVSpeechSynthesizerDelegate {
    var onFinished: ((PlaybackToken) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var attempts: [ObjectIdentifier: PlaybackToken] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func play(_ message: AudioMessage, token: PlaybackToken) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try session.setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: message.text)
        // es-MX: iOS pronuncia "0,3" como "cero coma tres" (separador decimal español).
        // Si el dispositivo no tiene la voz es-MX descargada, iOS cae en la más cercana disponible.
        utterance.voice = AVSpeechSynthesisVoice(language: "es-MX")
        attempts[ObjectIdentifier(utterance)] = token
        synthesizer.speak(utterance)
    }

    func stop() {
        attempts.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let token = self.attempts.removeValue(forKey: id) else { return }
            self.onFinished?(token)
            #if os(iOS)
            if self.attempts.isEmpty {
                try? AVAudioSession.sharedInstance().setActive(
                    false, options: [.notifyOthersOnDeactivation]
                )
            }
            #endif
        }
    }
}
#endif
