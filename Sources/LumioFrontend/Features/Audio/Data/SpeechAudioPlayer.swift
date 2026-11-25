#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Solo el árbitro debe usar esta instancia. No bloquea mientras habla.
/// Todas las locuciones (seguridad, navegación, narración y comandos de voz) salen con las
/// preferencias de voz aplicadas; un cambio vale desde la siguiente locución.
@MainActor
final class SpeechAudioPlayer: NSObject, AudioPlaying, VoiceOutputConfiguring, AVSpeechSynthesizerDelegate {
    var onFinished: ((PlaybackToken) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var attempts: [ObjectIdentifier: PlaybackToken] = [:]
    /// En memoria: reproducir nunca lee el disco ni espera a la red.
    private(set) var preferences = VoicePreferences.standard
    private var voice: AVSpeechSynthesisVoice?

    override init() {
        super.init()
        synthesizer.delegate = self
        voice = Self.systemVoice(for: preferences)
    }

    func play(_ message: AudioMessage, token: PlaybackToken) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try session.setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: message.text)
        utterance.voice = voice
        utterance.rate = SpeechRatePolicy.utteranceRate(
            for: preferences.speechRate,
            normal: AVSpeechUtteranceDefaultSpeechRate,
            minimum: AVSpeechUtteranceMinimumSpeechRate,
            maximum: AVSpeechUtteranceMaximumSpeechRate
        )
        attempts[ObjectIdentifier(utterance)] = token
        synthesizer.speak(utterance)
    }

    func stop() {
        attempts.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }

    func apply(_ preferences: VoicePreferences) {
        self.preferences = preferences
        voice = Self.systemVoice(for: preferences)
    }

    /// La voz elegida; si no está instalada, la del idioma; si tampoco, español de México
    /// (iOS pronuncia "0,3" como "cero coma tres"). Si nada de eso existe, iOS usa la más
    /// cercana disponible.
    private nonisolated static func systemVoice(for preferences: VoicePreferences) -> AVSpeechSynthesisVoice? {
        if let identifier = preferences.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: preferences.language)
            ?? AVSpeechSynthesisVoice(language: VoicePreferences.standard.language)
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
