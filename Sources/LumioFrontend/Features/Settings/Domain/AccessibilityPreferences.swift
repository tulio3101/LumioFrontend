import Foundation

/// SCRUM-32: Configurar Preferencias de Accesibilidad. Completan las de voz (SCRUM-27) y
/// vibración (SCRUM-28) en el mismo esquema: se leen siempre del teléfono, se guardan en un
/// JSON local y se aplican en memoria, así que nunca esperan al disco ni a la red y no pueden
/// retrasar una alerta de seguridad.
struct AccessibilityPreferences: Codable, Equatable {
    /// ADR-308: narración automática cuando cambia la escena (SCRUM-40). Viene activada y el
    /// usuario la puede apagar; la narración a pedido (SCRUM-39) sigue disponible.
    var autoNarration: Bool
    /// Decir el estado de Lumio (sesión, permisos, detección, ruta) al abrir la app.
    var announceStatusOnLaunch: Bool
    /// Cuánto explican los avisos generales.
    var announcementDetail: AnnouncementDetail

    static let standard = AccessibilityPreferences(
        autoNarration: true, announceStatusOnLaunch: true, announcementDetail: .detailed
    )

    init(autoNarration: Bool, announceStatusOnLaunch: Bool, announcementDetail: AnnouncementDetail) {
        self.autoNarration = autoNarration
        self.announceStatusOnLaunch = announceStatusOnLaunch
        self.announcementDetail = announcementDetail
    }

    /// Validación al leer: un campo ausente (archivo de una versión anterior) o un valor
    /// desconocido (de una versión futura) toma el valor predeterminado en lugar de perder
    /// todas las preferencias.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = Self.standard
        let auto: Bool? = try? container.decodeIfPresent(Bool.self, forKey: .autoNarration)
        let onLaunch: Bool? = try? container.decodeIfPresent(Bool.self, forKey: .announceStatusOnLaunch)
        let detail: AnnouncementDetail? = try? container.decodeIfPresent(
            AnnouncementDetail.self, forKey: .announcementDetail
        )
        autoNarration = auto ?? standard.autoNarration
        announceStatusOnLaunch = onLaunch ?? standard.announceStatusOnLaunch
        announcementDetail = detail ?? standard.announcementDetail
    }
}

enum AnnouncementDetail: String, Codable, CaseIterable, Identifiable {
    /// Solo el estado, sin explicar cómo usar la app.
    case brief
    /// El estado y las pistas de uso (cómo dictar el destino, dónde está la emergencia).
    case detailed

    var id: String { rawValue }

    var name: String {
        switch self {
        case .brief: "Breves"
        case .detailed: "Detallados"
        }
    }

    var explanation: String {
        switch self {
        case .brief: "Solo el estado, sin explicar cómo usar la app."
        case .detailed: "El estado y cómo usar las acciones rápidas."
        }
    }
}

protocol AccessibilityPreferencesStoring {
    func load() throws -> AccessibilityPreferences?
    func save(_ preferences: AccessibilityPreferences) throws
    func clear() throws
}

/// Lo que los módulos leen. Siempre en memoria.
@MainActor
protocol AccessibilityPreferencesReading: AnyObject {
    var preferences: AccessibilityPreferences { get }
}

/// Eliminar Cuenta (SCRUM-7) vuelve a las predeterminadas.
@MainActor
protocol AccessibilityPreferencesResetting: AnyObject {
    func resetToStandard()
}

enum AccessibilityPreferencesOutcome: Equatable {
    case saved
    case unchanged
    /// Se aplicó, pero no se pudo guardar en el teléfono: se pierde al cerrar la app.
    case appliedNotSaved
}

/// Pantalla Preferencias > Preferencias de accesibilidad.
@MainActor
protocol AccessibilityPreferencesManaging: AccessibilityPreferencesReading {
    var storedUnreadable: Bool { get }
    @discardableResult func update(_ preferences: AccessibilityPreferences) -> AccessibilityPreferencesOutcome
}

enum AccessibilityPreferencesAnnouncements {
    static let notSaved = "No se pudieron guardar las preferencias de accesibilidad en el teléfono. Se aplican hasta que cierres la app."
    static let unreadable = "No se pudieron leer tus preferencias de accesibilidad guardadas. Se usan las predeterminadas."
}
