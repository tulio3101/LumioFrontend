import Foundation

/// Configurar Retroalimentación Háptica:
///
/// 1. Al crearse (al abrir la app) lee las preferencias del teléfono. Un archivo dañado se
///    reemplaza por las predeterminadas y se avisa en la pantalla de Vibración.
/// 2. Es el HapticFeedbackPlaying de la app: cada evento (ruta lista, error, ruta terminada)
///    pasa por aquí, se filtra con las preferencias en memoria y vibra con su patrón. Nunca
///    espera al disco ni a la red.
/// 3. Las alertas críticas (P1 del AudioArbiter) vibran siempre con su patrón fuerte, sin
///    importar las preferencias: se detectan cuando el árbitro empieza a reproducirlas. Los
///    eventos del Botón de Emergencia también vibran siempre.
/// 4. Al cambiar algo lo aplica, lo guarda y, si no se pudo guardar, lo dice por audio.
@MainActor
final class HapticPreferencesService: HapticFeedbackPlaying, HapticPreferencesManaging, HapticPreferencesResetting {
    static let contextID = "haptic-preferences"

    private let store: any HapticPreferencesStoring
    private let player: (any HapticPatternPlaying)?
    private let arbiter: (any AudioArbitrating)?
    private let now: () -> Date

    private(set) var preferences: HapticPreferences
    private(set) var storedUnreadable: Bool

    init(
        store: any HapticPreferencesStoring,
        player: (any HapticPatternPlaying)?,
        arbiter: (any AudioArbitrating)?,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.player = player
        self.arbiter = arbiter
        self.now = now
        do {
            preferences = try store.load() ?? .standard
            storedUnreadable = false
        } catch {
            preferences = .standard
            storedUnreadable = true
        }
    }

    var supportsHaptics: Bool { player?.supportsHaptics ?? false }

    // MARK: Eventos

    func play(_ cue: HapticCue) {
        guard preferences.plays(cue) else { return }
        player?.play(HapticPattern.pattern(for: cue, intensity: preferences.intensity))
    }

    /// Conectado a AudioArbiterService.onMessageChanged: una alerta P1 que empieza a sonar
    /// vibra siempre.
    func audioMessageChanged(_ message: AudioMessage) {
        guard message.priority == .immediateRisk, message.status == .playing else { return }
        play(.criticalAlert)
    }

    // MARK: Preferencias

    func update(_ new: HapticPreferences) -> HapticPreferencesOutcome {
        guard new != preferences else { return .unchanged }
        preferences = new
        storedUnreadable = false
        do {
            try store.save(new)
            return .saved
        } catch {
            speak(HapticPreferencesAnnouncements.notSaved)
            return .appliedNotSaved
        }
    }

    func preview(_ cue: HapticCue) {
        player?.play(HapticPattern.pattern(for: cue, intensity: preferences.intensity))
    }

    func resetToStandard() {
        try? store.clear()
        storedUnreadable = false
        preferences = .standard
    }

    private func speak(_ text: String) {
        guard let arbiter else { return }
        arbiter.cancel(contextIDs: [Self.contextID])
        arbiter.receive(AudioMessage(
            text: text,
            priority: .routeInformation,
            createdAt: now(),
            expiresAt: now().addingTimeInterval(30),
            contextID: Self.contextID,
            deduplicationKey: "not-saved"
        ))
    }
}
