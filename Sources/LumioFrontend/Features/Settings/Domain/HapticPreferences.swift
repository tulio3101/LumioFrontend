import Foundation

/// Configurar Retroalimentación Háptica: activar o desactivar la vibración, elegir qué
/// eventos vibran y con qué intensidad. Se guardan en el teléfono; no dependen del backend.
/// Las alertas críticas (P1) no son configurables: siempre vibran con su patrón fuerte.
struct HapticPreferences: Codable, Equatable {
    var isEnabled: Bool
    var intensity: HapticIntensity
    /// Se guardan los eventos apagados: un evento nuevo en una versión futura vibra por
    /// defecto.
    var disabledCues: Set<HapticCue>

    static let standard = HapticPreferences(isEnabled: true, intensity: .medium, disabledCues: [])

    /// Si el evento vibra con estas preferencias. Las alertas críticas siempre vibran.
    func plays(_ cue: HapticCue) -> Bool {
        guard cue.isConfigurable else { return true }
        return isEnabled && !disabledCues.contains(cue)
    }
}

enum HapticIntensity: String, Codable, CaseIterable, Identifiable {
    case soft, medium, strong

    var id: String { rawValue }

    var name: String {
        switch self {
        case .soft: "Suave"
        case .medium: "Media"
        case .strong: "Fuerte"
        }
    }

    /// Multiplica la fuerza de cada pulso del patrón.
    var scale: Double {
        switch self {
        case .soft: 0.45
        case .medium: 0.75
        case .strong: 1
        }
    }
}

extension HapticCue {
    /// Los eventos que el usuario puede apagar, en el orden de la pantalla.
    static let configurable: [HapticCue] = allCases.filter(\.isConfigurable)

    var isConfigurable: Bool { self != .criticalAlert }

    var name: String {
        switch self {
        case .routeReady: "Ruta lista"
        case .routeFailed: "No se pudo calcular la ruta"
        case .routeFinished: "Ruta terminada"
        case .criticalAlert: "Alerta de seguridad"
        }
    }

    /// Cómo se siente el patrón; se muestra y lo lee VoiceOver.
    var patternDescription: String {
        switch self {
        case .routeReady: "Dos toques cortos."
        case .routeFailed: "Un toque fuerte, una pausa y un toque suave."
        case .routeFinished: "Tres toques que van subiendo."
        case .criticalAlert: "Cuatro toques fuertes y rápidos."
        }
    }
}

// MARK: - Patrones

/// Un toque del motor de vibración.
struct HapticPulse: Equatable {
    /// Segundos desde el inicio del patrón.
    let delay: TimeInterval
    /// 0 a 1.
    let strength: Double
}

struct HapticPattern: Equatable {
    let pulses: [HapticPulse]

    /// El patrón de cada evento. Cada uno tiene un ritmo distinto para reconocerlo sin
    /// escuchar el audio. La alerta crítica no se escala con la intensidad elegida.
    static func pattern(for cue: HapticCue, intensity: HapticIntensity) -> HapticPattern {
        let base: [HapticPulse]
        switch cue {
        case .routeReady:
            base = [HapticPulse(delay: 0, strength: 1), HapticPulse(delay: 0.15, strength: 1)]
        case .routeFailed:
            base = [HapticPulse(delay: 0, strength: 1), HapticPulse(delay: 0.45, strength: 0.5)]
        case .routeFinished:
            base = [
                HapticPulse(delay: 0, strength: 0.5),
                HapticPulse(delay: 0.15, strength: 0.75),
                HapticPulse(delay: 0.3, strength: 1),
            ]
        case .criticalAlert:
            return HapticPattern(pulses: [0, 0.1, 0.2, 0.3].map { HapticPulse(delay: $0, strength: 1) })
        }
        return HapticPattern(pulses: base.map {
            HapticPulse(delay: $0.delay, strength: min(1, $0.strength * intensity.scale))
        })
    }
}

// MARK: - Contratos

/// El motor de vibración del teléfono.
@MainActor
protocol HapticPatternPlaying: AnyObject {
    /// Falso en dispositivos sin motor de vibración (por ejemplo, un iPad).
    var supportsHaptics: Bool { get }
    func play(_ pattern: HapticPattern)
}

/// Copia de las preferencias en el teléfono. Es la única fuente al abrir la app.
protocol HapticPreferencesStoring {
    func load() throws -> HapticPreferences?
    func save(_ preferences: HapticPreferences) throws
    func clear() throws
}

enum HapticPreferencesOutcome: Equatable {
    case saved
    case unchanged
    /// Aplicadas, pero no se pudieron guardar: al cerrar la app vuelven las anteriores.
    case appliedNotSaved
}

/// Consultar y cambiar las preferencias hápticas. Lo usa la pantalla de Preferencias.
@MainActor
protocol HapticPreferencesManaging: AnyObject {
    var preferences: HapticPreferences { get }
    var supportsHaptics: Bool { get }
    /// El archivo guardado no se pudo leer al abrir la app; se usan las predeterminadas.
    var storedUnreadable: Bool { get }
    func update(_ preferences: HapticPreferences) -> HapticPreferencesOutcome
    /// Vibra el patrón del evento con la intensidad elegida, aunque el evento esté apagado.
    func preview(_ cue: HapticCue)
}

/// Eliminar Cuenta (SCRUM-7) borra las preferencias del teléfono.
@MainActor
protocol HapticPreferencesResetting: AnyObject {
    func resetToStandard()
}

// MARK: - Textos

enum HapticPreferencesAnnouncements {
    static let notSaved = "Se aplicó el cambio de vibración, pero no se pudo guardar en el teléfono. "
        + "Al cerrar la app volverá la configuración anterior."
    static let storedUnreadable = "No se pudieron leer tus preferencias de vibración guardadas. "
        + "Se usan las predeterminadas."
    static let criticalAlwaysOn = "Las alertas de seguridad siempre vibran, aunque desactives la vibración."
    static let unsupported = "Este dispositivo no tiene vibración. Las alertas siguen llegando por audio."

    static func summary(_ preferences: HapticPreferences) -> String {
        guard preferences.isEnabled else { return "Vibración desactivada. \(criticalAlwaysOn)" }
        let off = HapticCue.configurable.filter { preferences.disabledCues.contains($0) }
        let events = off.isEmpty
            ? "Todos los eventos vibran."
            : "Sin vibración: " + off.map(\.name).joined(separator: ", ") + "."
        return "Vibración activada. Intensidad \(preferences.intensity.name.lowercased()). \(events)"
    }
}
