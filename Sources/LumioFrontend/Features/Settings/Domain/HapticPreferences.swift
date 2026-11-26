import Foundation

/// Configurar Retroalimentación Háptica: activar o desactivar la vibración, elegir qué
/// eventos vibran y con qué intensidad. Se guardan en el teléfono; no dependen del backend.
/// Las alertas críticas (P1) y las del Botón de Emergencia no son configurables: siempre
/// vibran con su patrón, sin escalar por la intensidad.
struct HapticPreferences: Codable, Equatable {
    var isEnabled: Bool
    var intensity: HapticIntensity
    /// Se guardan los eventos apagados: un evento nuevo en una versión futura vibra por
    /// defecto.
    var disabledCues: Set<HapticCue>

    static let standard = HapticPreferences(isEnabled: true, intensity: .medium, disabledCues: [])

    /// Si el evento vibra con estas preferencias. Las alertas de seguridad siempre vibran.
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
    /// Alertas de seguridad: vibran siempre, aunque la vibración esté desactivada.
    static let alwaysOn: [HapticCue] = allCases.filter { !$0.isConfigurable }

    var isConfigurable: Bool {
        switch self {
        case .routeReady, .routeFailed, .routeFinished, .turnLeft, .turnRight: true
        // «Detección lista» y los desniveles/obstáculos acompañan a la seguridad: vibran siempre.
        case .emergencyActivated, .emergencySent, .emergencyFailed, .criticalAlert, .safetyReady,
             .danger, .warning: false
        }
    }

    var name: String {
        switch self {
        case .routeReady: "Ruta lista"
        case .routeFailed: "No se pudo calcular la ruta"
        case .routeFinished: "Ruta terminada"
        case .turnLeft: "Giro a la izquierda"
        case .turnRight: "Giro a la derecha"
        case .emergencyActivated: "Emergencia activada"
        case .emergencySent: "Alerta de emergencia enviada"
        case .emergencyFailed: "No se pudo enviar la emergencia"
        case .criticalAlert: "Alerta de seguridad"
        case .safetyReady: "Detección de obstáculos lista"
        case .danger: "Desnivel hacia abajo"
        case .warning: "Desnivel hacia arriba u obstáculo cercano"
        }
    }

    /// Cómo se siente el patrón; se muestra y lo lee VoiceOver.
    var patternDescription: String {
        switch self {
        case .routeReady: "Dos toques cortos."
        case .routeFailed: "Un toque fuerte, una pausa y un toque suave."
        case .routeFinished: "Tres toques que van subiendo."
        case .turnLeft: "Dos toques lentos."
        case .turnRight: "Tres toques lentos."
        case .emergencyActivated: "Tres toques fuertes y espaciados."
        case .emergencySent: "Dos toques rápidos, una pausa y un toque."
        case .emergencyFailed: "Dos pares de toques fuertes."
        case .criticalAlert: "Cuatro toques fuertes y rápidos."
        case .safetyReady: "Un toque suave y uno fuerte."
        case .danger: "Tres toques fuertes seguidos."
        case .warning: "Dos toques medios."
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
    /// escuchar el audio. Las alertas de seguridad no se escalan con la intensidad elegida.
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
        case .turnLeft:
            // Izquierda y derecha: mismo ritmo lento, se distinguen por el número de toques. Lento
            // a propósito para no confundirse con los toques seguidos de un desnivel (danger).
            base = [HapticPulse(delay: 0, strength: 1), HapticPulse(delay: 0.35, strength: 1)]
        case .turnRight:
            base = [
                HapticPulse(delay: 0, strength: 1),
                HapticPulse(delay: 0.35, strength: 1),
                HapticPulse(delay: 0.7, strength: 1),
            ]
        case .emergencyActivated:
            return .full([0, 0.25, 0.5])
        case .emergencySent:
            return .full([0, 0.12, 0.5])
        case .emergencyFailed:
            return .full([0, 0.1, 0.5, 0.6])
        case .criticalAlert:
            return .full([0, 0.1, 0.2, 0.3])
        case .safetyReady:
            return HapticPattern(pulses: [HapticPulse(delay: 0, strength: 0.4), HapticPulse(delay: 0.2, strength: 1)])
        case .danger:
            // SCRUM-33: bajada = 3 toques fuertes seguidos (no se escala con la intensidad).
            return .full([0, 0.12, 0.24])
        case .warning:
            // SCRUM-33: subida u obstáculo cercano = 2 toques medios.
            return HapticPattern(pulses: [
                HapticPulse(delay: 0, strength: 0.75), HapticPulse(delay: 0.12, strength: 0.75),
            ])
        }
        return HapticPattern(pulses: base.map {
            HapticPulse(delay: $0.delay, strength: min(1, $0.strength * intensity.scale))
        })
    }

    /// Toques a fuerza máxima en esos instantes.
    private static func full(_ delays: [TimeInterval]) -> HapticPattern {
        HapticPattern(pulses: delays.map { HapticPulse(delay: $0, strength: 1) })
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
    static let criticalAlwaysOn = "Las alertas de seguridad y las del botón de emergencia siempre vibran, "
        + "aunque desactives la vibración."
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
