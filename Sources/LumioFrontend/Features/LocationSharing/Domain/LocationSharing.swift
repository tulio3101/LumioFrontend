import Foundation

/// SCRUM-25: Compartir Ubicación. El backend envía a los contactos de confianza un enlace
/// privado con la última posición; la app la actualiza mientras dure. Solo correo y una página:
/// sin push ni app del acompañante (fuera del MVP).
struct LocationShare: Equatable {
    let id: UUID
    let expiresAt: Date
    let contactsTotal: Int
    let contactsSent: Int
}

struct SharedPosition: Equatable {
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double?
}

enum LocationSharingState: Equatable {
    case idle
    case starting
    /// `isOffline`: sin conexión, la página muestra la última posición que llegó.
    case sharing(LocationShare, isOffline: Bool)
    case stopping
}

/// `POST /location-shares`, `PUT …/{id}/position` y `DELETE …/{id}`.
protocol LocationSharingRemoting {
    func start(at position: SharedPosition, durationMinutes: Int) async throws -> LocationShare
    func update(_ shareID: UUID, to position: SharedPosition) async throws
    func stop(_ shareID: UUID) async throws
}

/// Por qué no se pudo compartir o se dejó de compartir.
enum LocationSharingFailure: Equatable {
    case locationPermissionDenied
    case locationUnavailable
    case offline
    case noTrustedContacts
    case deliveryFailed
    case sessionRequired
    case notConfigured
    case serviceUnavailable
}

/// Cierre de sesión y eliminación de cuenta dejan de compartir.
@MainActor
protocol LocationSharingStopping: AnyObject {
    func stopSharing() async
}

enum LocationSharingPolicy {
    /// Cada cuánto se envía la posición mientras se comparte.
    static let updateInterval: TimeInterval = 30
    static let durations = [30, 60, 120]
    static let defaultDuration = 60
}

enum LocationSharingAnnouncements {
    static let explanation = """
    Tus contactos de confianza reciben un correo con un enlace privado para ver tu ubicación \
    actual mientras la compartes. Solo ven la última posición, no un historial. Deja de \
    compartirse cuando tú lo detengas o al terminar el tiempo que elijas.
    """

    static func confirmation(minutes: Int) -> String {
        "¿Compartir tu ubicación con tus contactos de confianza durante \(duration(minutes))?"
    }

    static func started(_ share: LocationShare, now: Date = Date()) -> String {
        let who = share.contactsSent == 1 ? "1 contacto" : "\(share.contactsSent) contactos"
        var text = "Estás compartiendo tu ubicación con \(who) hasta las \(time(share.expiresAt))."
        if share.contactsSent < share.contactsTotal {
            text += " No se pudo avisar a \(share.contactsTotal - share.contactsSent)."
        }
        return text
    }

    static let stopped = "Dejaste de compartir tu ubicación."
    static let stoppedOffline = "Dejaste de compartir tu ubicación en este teléfono. Sin conexión no se pudo cerrar el enlace: tus contactos verán la última posición hasta que venza."
    static let expired = "Terminó el tiempo: ya no compartes tu ubicación."
    static let offline = "Sin conexión: tu ubicación no se está actualizando. Tus contactos ven la última que llegó."
    static let reconnected = "Volvió la conexión: tu ubicación se actualiza de nuevo."

    static func failure(_ failure: LocationSharingFailure) -> String {
        switch failure {
        case .locationPermissionDenied:
            return "Para compartir tu ubicación, Lumio necesita permiso de ubicación. Puedes concederlo en Preferencias, Permisos."
        case .locationUnavailable:
            return "No pude obtener tu ubicación. Inténtalo de nuevo en un lugar con mejor señal."
        case .offline:
            return "Sin conexión no se puede compartir la ubicación. Inténtalo cuando vuelva la red."
        case .noTrustedContacts:
            return "No tienes contactos de confianza. Agrégalos en Preferencias, Emergencia, Contactos de confianza."
        case .deliveryFailed:
            return "No se pudo avisar a ningún contacto. No se está compartiendo tu ubicación."
        case .sessionRequired:
            return "Para compartir tu ubicación necesitas iniciar sesión."
        case .notConfigured:
            return "Compartir la ubicación no está disponible en esta versión."
        case .serviceUnavailable:
            return "No se pudo compartir tu ubicación ahora. Inténtalo de nuevo."
        }
    }

    static func duration(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hora" : "\(hours) horas"
        }
        return "\(minutes) minutos"
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_CO")
        formatter.timeZone = TimeZone(identifier: "America/Bogota")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
