#if canImport(AVFoundation)
import AVFoundation

/// Voces en español instaladas en el teléfono (AVSpeechSynthesisVoice). Las voces mejoradas
/// y premium aparecen solo si el usuario las descargó en Ajustes.
struct SystemVoiceCatalog: VoiceCatalogProviding {
    func availableLanguages() -> [VoiceLanguageOption] {
        let codes = Set(spanishVoices().map(\.language))
        return codes
            .map { VoiceLanguageOption(code: $0, name: VoiceLanguageNames.name(for: $0)) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func availableVoices(language: String) -> [VoiceOption] {
        spanishVoices()
            .filter { $0.language == language }
            .map { voice in
                VoiceOption(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    isEnhanced: voice.quality != .default
                )
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private func spanishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.lowercased().hasPrefix("es") }
    }
}
#endif
