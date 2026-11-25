import Foundation
#if canImport(Combine)
import Combine
#endif

#if canImport(Combine)
/// Estado de la pantalla Preferencias de voz. Validar, aplicar, guardar y locutar lo hace
/// VoicePreferencesService; aquí solo se refleja en la pantalla.
@MainActor
final class VoicePreferencesViewModel: ObservableObject {
    struct Banner: Equatable {
        enum Kind: Equatable { case success, warning, error }
        let kind: Kind
        let title: String
        let message: String
    }

    @Published private(set) var preferences: VoicePreferences
    @Published private(set) var languages: [VoiceLanguageOption] = []
    @Published private(set) var voices: [VoiceOption] = []
    @Published private(set) var banner: Banner?

    private let service: any VoicePreferencesManaging

    init(service: any VoicePreferencesManaging) {
        self.service = service
        preferences = service.preferences
    }

    var languageName: String {
        VoicePreferencesAnnouncements.languageName(preferences.language, catalog: languages)
    }

    var voiceName: String {
        VoicePreferencesAnnouncements.voiceName(preferences.voiceIdentifier, voices: voices)
    }

    var rateName: String { SpeechRatePolicy.spokenName(for: preferences.speechRate) }

    /// Consultar las preferencias actuales: lo que VoiceOver lee en el resumen.
    var summary: String {
        VoicePreferencesAnnouncements.summary(
            language: languageName, voice: voiceName, rate: preferences.speechRate
        )
    }

    var canSlowDown: Bool { preferences.speechRate - SpeechRatePolicy.step >= SpeechRatePolicy.range.lowerBound }
    var canSpeedUp: Bool { preferences.speechRate + SpeechRatePolicy.step <= SpeechRatePolicy.range.upperBound }

    /// Al abrir la pantalla: lo instalado ahora en el teléfono y lo que no se pudo aplicar
    /// de lo guardado.
    func load() {
        refresh()
        let issues = service.launchIssues
        guard !issues.isEmpty else { return }
        banner = Banner(
            kind: .warning,
            title: "Se ajustaron tus preferencias",
            message: issues
                .map { VoicePreferencesAnnouncements.launchMessage(for: $0, current: languageName) }
                .joined(separator: " ")
        )
    }

    /// Otro idioma usa su voz predeterminada: las voces de un idioma no sirven para otro.
    func selectLanguage(_ code: String) {
        var new = preferences
        new.language = code
        new.voiceIdentifier = nil
        commit(new)
    }

    func selectVoice(_ identifier: String?) {
        var new = preferences
        new.voiceIdentifier = identifier
        commit(new)
    }

    func setRate(_ rate: Double) {
        var new = preferences
        new.speechRate = rate
        commit(new)
    }

    func slowDown() { setRate(preferences.speechRate - SpeechRatePolicy.step) }
    func speedUp() { setRate(preferences.speechRate + SpeechRatePolicy.step) }

    func preview() { service.preview() }

    private func commit(_ new: VoicePreferences) {
        let outcome = service.update(new)
        refresh()
        switch outcome {
        case .unchanged:
            break
        case .saved:
            banner = Banner(kind: .success, title: "Preferencias guardadas", message: summary)
        case .appliedNotSaved:
            banner = Banner(kind: .warning, title: "No se guardó el cambio", message: VoicePreferencesAnnouncements.notSaved)
        case .rejected(let issue):
            banner = Banner(
                kind: .error,
                title: "No se pudo aplicar",
                message: VoicePreferencesAnnouncements.message(
                    for: issue,
                    languageName: VoicePreferencesAnnouncements.languageName(new.language, catalog: languages)
                )
            )
        }
    }

    private func refresh() {
        preferences = service.preferences
        languages = service.availableLanguages()
        voices = service.availableVoices(language: preferences.language)
    }
}
#endif
