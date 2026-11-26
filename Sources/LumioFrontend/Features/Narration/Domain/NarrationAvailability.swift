import Foundation

/// SCRUM-41: Gestionar Disponibilidad de la Narración.
///
/// La narración es el único loop que necesita red (nivel 3 de degradación). Este estado lo
/// leen `EnvironmentNarrationService` (botón) y `AutoNarrationScheduler` (automáticas); la
/// detección de obstáculos, los giros y la navegación nunca dependen de él.
enum NarrationAvailability: Equatable {
    /// Aún no se sabe (al empezar la ruta). No bloquea: la primera solicitud se intenta.
    case checking
    case available
    case unavailable(NarrationOutage)

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// Por qué no hay narración, para decirlo con claridad.
enum NarrationOutage: Equatable {
    /// El teléfono no tiene red o no llega al servidor.
    case offline
    /// El servidor responde, pero la narración está caída, saturada o sin configurar.
    case serviceDown
}

/// Lo que responde `GET /vision/status`.
enum NarrationServiceStatus: Equatable {
    case available
    /// El backend dice que no hay narración; `retryAfter` es cuándo conviene volver a mirar.
    case unavailable(retryAfter: TimeInterval?)
    /// La consulta no llegó al servidor (sin red, DNS, timeout).
    case unreachable
}

/// Consulta el estado de la narración sin enviar fotos ni gastar cupo.
protocol NarrationStatusChecking: AnyObject {
    func checkStatus() async -> NarrationServiceStatus
}

/// Política durante una caída (SCRUM-41):
/// - Las automáticas no se envían: no hay cola, porque una foto vieja ya no describe lo que el
///   usuario tiene delante (ADR-308, 4 s).
/// - El botón responde enseguida que la narración sigue sin estar disponible (P2) y pide una
///   comprobación inmediata; si el servicio volvió, se avisa «Narración disponible de nuevo»
///   y la siguiente pulsación funciona.
/// - Al volver, las automáticas se reanudan solas, sin esperar la pausa por fallas.
@MainActor
protocol NarrationAvailabilityObserving: AnyObject {
    var availability: NarrationAvailability { get }
    /// Cada cambio de estado (para la pantalla y para reanudar las automáticas).
    var onChange: ((NarrationAvailability) -> Void)? { get set }
    /// Vigila mientras la pantalla de la ruta está abierta.
    func start()
    func stop()
    /// Comprueba ya, sin esperar al temporizador (p. ej., al pulsar el botón durante una caída).
    func recheck()
    /// Una descripción llegó: la narración funciona.
    func narrationSucceeded()
    /// Una solicitud falló. `userNotified`: el usuario ya oyó el motivo (botón), así que la
    /// caída no se vuelve a anunciar.
    func narrationFailed(_ reason: EnvironmentNarrationUnavailable, userNotified: Bool)
}
