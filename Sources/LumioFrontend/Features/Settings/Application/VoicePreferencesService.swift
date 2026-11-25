import Foundation

/// Configurar Preferencias de Voz Descriptiva:
///
/// 1. Al crearse (al abrir la app) lee las preferencias del teléfono y las aplica al
///    reproductor del AudioArbiter antes de cualquier locución. Lo guardado que ya no se
///    puede usar (una voz desinstalada, un archivo dañado) se reemplaza por lo predeterminado
///    sin perder lo demás, y se informa en la pantalla de Preferencias de voz.
/// 2. Al cambiar algo, valida contra las voces instaladas. Si no se puede aplicar, no cambia
///    nada y lo dice. Si se puede, lo aplica (en memoria, inmediato), lo guarda en el teléfono
///    y lo confirma por audio con la configuración nueva.
/// 3. No hay sincronización con el backend: aplicar nunca espera a la red, así que no puede
///    retrasar una alerta de seguridad.
///
/// Todo lo que dice pasa por el AudioArbiter como P2: una alerta P1 siempre lo interrumpe.
@MainActor
final class VoicePreferencesService: VoicePreferencesManaging, VoicePreferencesResetting {
    static let contextID = "voice-preferences"

    private let store: any VoicePreferencesStoring
    private let catalog: any VoiceCatalogProviding
    private let output: (any VoiceOutputConfiguring)?
    private let arbiter: (any AudioArbitrating)?
    private let now: () -> Date

    private(set) var preferences: VoicePreferences
    private(set) var launchIssues: [VoicePreferenceIssue]

    init(
        store: any VoicePreferencesStoring,
        catalog: any VoiceCatalogProviding,
        output: (any VoiceOutputConfiguring)?,
        arbiter: (any AudioArbitrating)?,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.catalog = catalog
        self.output = output
        self.arbiter = arbiter
        self.now = now

        var issues: [VoicePreferenceIssue] = []
        let stored: VoicePreferences
        do {
            stored = try store.load() ?? .standard
        } catch {
            stored = .standard
            issues.append(.storedUnreadable)
        }
        let usable = VoicePreferencesPolicy.usable(stored, catalog: catalog)
        preferences = usable.preferences
        launchIssues = issues + usable.issues
        output?.apply(usable.preferences)
    }

    func availableLanguages() -> [VoiceLanguageOption] {
        catalog.availableLanguages()
    }

    func availableVoices(language: String) -> [VoiceOption] {
        catalog.availableVoices(language: language)
    }

    func update(_ new: VoicePreferences) -> VoicePreferencesOutcome {
        guard new != preferences else { return .unchanged }
        if let issue = VoicePreferencesPolicy.issue(with: new, catalog: catalog) {
            let name = VoicePreferencesAnnouncements.languageName(new.language, catalog: availableLanguages())
            speak(VoicePreferencesAnnouncements.message(for: issue, languageName: name), key: "rejected")
            return .rejected(issue)
        }

        let old = preferences
        preferences = new
        // Ya no aplican los avisos de lo que se ajustó al abrir: el usuario eligió de nuevo.
        launchIssues = []
        output?.apply(new)

        let outcome: VoicePreferencesOutcome
        do {
            try store.save(new)
            outcome = .saved
        } catch {
            outcome = .appliedNotSaved
        }
        let confirmation = VoicePreferencesAnnouncements.confirmation(
            from: old, to: new,
            language: VoicePreferencesAnnouncements.languageName(new.language, catalog: availableLanguages()),
            voice: VoicePreferencesAnnouncements.voiceName(
                new.voiceIdentifier, voices: availableVoices(language: new.language)
            )
        )
        speak(
            outcome == .saved ? confirmation : VoicePreferencesAnnouncements.notSaved,
            key: "outcome"
        )
        return outcome
    }

    func preview() {
        speak(VoicePreferencesAnnouncements.sample, key: "preview")
    }

    /// Eliminar Cuenta: borra la copia del teléfono y vuelve a la voz predeterminada.
    func resetToStandard() {
        try? store.clear()
        launchIssues = []
        preferences = VoicePreferencesPolicy.usable(.standard, catalog: catalog).preferences
        output?.apply(preferences)
    }

    /// Un mensaje nuevo reemplaza al anterior: al subir la velocidad varias veces seguidas
    /// solo se oye la última confirmación.
    private func speak(_ text: String, key: String) {
        guard let arbiter else { return }
        arbiter.cancel(contextIDs: [Self.contextID])
        arbiter.receive(AudioMessage(
            text: text,
            priority: .routeInformation,
            createdAt: now(),
            expiresAt: now().addingTimeInterval(30),
            contextID: Self.contextID,
            deduplicationKey: key
        ))
    }
}
