import Foundation
#if canImport(Combine)
import Combine

/// Estado de la pantalla Vibración. Aplicar y guardar lo hace HapticPreferencesService.
@MainActor
final class HapticPreferencesViewModel: ObservableObject {
    struct Banner: Equatable {
        enum Kind: Equatable { case warning, error }
        let kind: Kind
        let title: String
        let message: String
    }

    @Published private(set) var preferences: HapticPreferences
    @Published private(set) var banner: Banner?

    private let service: any HapticPreferencesManaging

    init(service: any HapticPreferencesManaging) {
        self.service = service
        preferences = service.preferences
    }

    var supportsHaptics: Bool { service.supportsHaptics }
    var summary: String { HapticPreferencesAnnouncements.summary(preferences) }

    func load() {
        preferences = service.preferences
        if service.storedUnreadable {
            banner = Banner(
                kind: .warning, title: "Se ajustaron tus preferencias",
                message: HapticPreferencesAnnouncements.storedUnreadable
            )
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        var new = preferences
        new.isEnabled = isEnabled
        commit(new)
    }

    func isOn(_ cue: HapticCue) -> Bool { !preferences.disabledCues.contains(cue) }

    /// Al encender un evento se siente su patrón: confirma el cambio sin mirar la pantalla.
    func setCue(_ cue: HapticCue, on: Bool) {
        var new = preferences
        if on {
            new.disabledCues.remove(cue)
        } else {
            new.disabledCues.insert(cue)
        }
        if commit(new), on { service.preview(cue) }
    }

    /// Al cambiar la intensidad se siente un ejemplo con la nueva.
    func setIntensity(_ intensity: HapticIntensity) {
        var new = preferences
        new.intensity = intensity
        if commit(new) { service.preview(.routeReady) }
    }

    func preview(_ cue: HapticCue) { service.preview(cue) }

    /// Verdadero si el cambio quedó aplicado.
    @discardableResult
    private func commit(_ new: HapticPreferences) -> Bool {
        let outcome = service.update(new)
        preferences = service.preferences
        switch outcome {
        case .unchanged:
            return false
        case .saved:
            banner = nil
            return true
        case .appliedNotSaved:
            banner = Banner(kind: .error, title: "No se guardó el cambio", message: HapticPreferencesAnnouncements.notSaved)
            return true
        }
    }
}
#endif
