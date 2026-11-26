import Foundation

/// Ubicación que viaja en la alerta de emergencia. Sin permiso o sin señal GPS no hay.
struct EmergencyLocation: Equatable {
    let latitude: Double
    let longitude: Double
    /// Radio de incertidumbre en metros.
    let accuracyMeters: Double?
}

/// Una activación del botón de emergencia. La llave identifica la alerta: reenviarla no manda
/// correos dobles.
struct EmergencyAlert: Equatable {
    let idempotencyKey: UUID
    let location: EmergencyLocation?
}

/// Lo que respondió el backend: a cuántos contactos llegó el correo.
struct EmergencyDelivery: Equatable {
    let contactsTotal: Int
    let contactsSent: Int
    /// El correo llevó la ubicación.
    let locationIncluded: Bool

    var reachedEveryone: Bool { contactsSent >= contactsTotal }
}

/// Ubicación actual para la alerta. nil si no hay permiso o no hay posición a tiempo; nunca
/// pide permiso (en una emergencia no se interrumpe al usuario con un diálogo del sistema).
@MainActor
protocol EmergencyLocating {
    func currentLocation() async -> EmergencyLocation?
}

/// Plataformas sin ubicación (pruebas, macOS): la alerta sale sin ella.
struct NoEmergencyLocation: EmergencyLocating {
    func currentLocation() async -> EmergencyLocation? { nil }
}

/// POST /sos con la sesión actual.
protocol EmergencyRemoting {
    func send(_ alert: EmergencyAlert) async throws -> EmergencyDelivery
}

/// Por qué la alerta no salió. Ninguno deja una alerta a medias: o llegó a algún contacto o no.
enum EmergencyFailure: Error, Equatable {
    case offline
    /// La sesión ya no vale: hay que volver a iniciar sesión.
    case sessionExpired
    /// No hay contactos de confianza (409): no se envió nada.
    case noContacts
    /// El correo no salió a ningún contacto (502).
    case deliveryFailed
    /// Error del servidor o backend no configurado.
    case server

    /// «Reintentar» tiene sentido: la alerta no llegó por algo que puede arreglarse.
    var canRetry: Bool {
        switch self {
        case .offline, .deliveryFailed, .server: true
        case .sessionExpired, .noContacts: false
        }
    }
}

enum EmergencyPhase: Equatable {
    case idle
    /// Margen para cancelar; `secondsRemaining` baja de EmergencyService.countdownSeconds a 1.
    case countingDown(secondsRemaining: Int)
    case sending
    case sent(EmergencyDelivery)
    case failed(EmergencyFailure)
    /// El usuario canceló durante el margen: no se envió nada.
    case cancelled

    /// No se puede empezar otra alerta ni descartar este estado.
    var isBusy: Bool {
        switch self {
        case .countingDown, .sending: true
        case .idle, .sent, .failed, .cancelled: false
        }
    }
}

/// Botón de Emergencia (SCRUM-35): activar, cancelar durante el margen, enviar y reintentar.
@MainActor
protocol EmergencyManaging: AnyObject {
    var phase: EmergencyPhase { get }
    /// Se llama en cada cambio de fase, también en la cuenta atrás.
    var onPhaseChange: ((EmergencyPhase) -> Void)? { get set }
    /// Empieza el margen para cancelar. Si ya hay una alerta en curso, no hace nada.
    func activate()
    /// Cancela durante el margen. Fuera de él no hace nada: ya se está enviando.
    func cancel()
    /// Reenvía la última alerta que falló, sin nueva cuenta atrás.
    func retry()
    /// Quita el resultado de la pantalla (enviada, fallida o cancelada).
    func dismiss()
}

// MARK: - Textos

/// Lo que se muestra es lo mismo que se locuta. Todo fallo recuerda el 123: la función no
/// sustituye a los servicios de emergencia.
enum EmergencyAnnouncements {
    static let emergencyLine = "123"
    static let disclaimer =
        "Lumio no sustituye a los servicios de emergencia. Si estás en peligro, llama al \(emergencyLine)."

    static func activated(seconds: Int) -> String {
        "Emergencia activada. Se enviará una alerta por correo a tus contactos de confianza en "
            + "\(seconds) segundos. Para cancelar, toca el botón Cancelar. \(disclaimer)"
    }

    static func countdown(_ seconds: Int) -> String {
        "Se envía en \(seconds) segundos. Toca Cancelar para detenerla."
    }

    static let cancelled = "Alerta cancelada. No se envió nada."
    static let sending = "Enviando la alerta."

    private static func contacts(_ count: Int) -> String {
        count == 1 ? "1 contacto" : "\(count) contactos"
    }

    private static let withoutLocation =
        " No se pudo obtener tu ubicación, así que se envió sin ella."

    static func sent(_ delivery: EmergencyDelivery) -> String {
        let place = delivery.locationIncluded ? "" : withoutLocation
        if delivery.reachedEveryone {
            return "Alerta enviada a \(contacts(delivery.contactsSent))." + place
        }
        return "Alerta enviada solo a \(delivery.contactsSent) de \(contacts(delivery.contactsTotal))."
            + " El correo no llegó a los demás." + place + " \(disclaimer)"
    }

    static func failed(_ failure: EmergencyFailure) -> String {
        switch failure {
        case .offline:
            "Sin conexión. No se pudo enviar la alerta. Toca Reintentar cuando tengas conexión. \(disclaimer)"
        case .sessionExpired:
            "Tu sesión expiró y no se envió la alerta. Inicia sesión de nuevo. \(disclaimer)"
        case .noContacts:
            "No tienes contactos de confianza, así que no se envió la alerta. "
                + "Agrégalos en Preferencias. \(disclaimer)"
        case .deliveryFailed:
            "No se pudo enviar la alerta a ninguno de tus contactos. Toca Reintentar. \(disclaimer)"
        case .server:
            "No se pudo enviar la alerta. Toca Reintentar. \(disclaimer)"
        }
    }

    static func message(for phase: EmergencyPhase) -> String? {
        switch phase {
        case .idle: nil
        case .countingDown(let seconds): countdown(seconds)
        case .sending: sending
        case .sent(let delivery): sent(delivery)
        case .failed(let failure): failed(failure)
        case .cancelled: cancelled
        }
    }
}
