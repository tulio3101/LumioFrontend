import Foundation

/// Avisos de audio del ciclo de sesión (SCRUM-360). Prioridad de navegación (`routeInformation`),
/// con su propio contexto para no mezclarse con rutas ni seguridad.
enum SessionAudio {
    static let context = "session"

    /// Se emite DESPUÉS de `resetSession()` en el teardown, para que sobreviva al vaciado de la cola.
    static func closed() -> AudioMessage {
        AudioMessage(
            text: "Sesión cerrada.",
            priority: .routeInformation,
            contextID: context,
            deduplicationKey: "session-closed"
        )
    }

    /// Expiró la sesión con una ruta activa: la navegación y la detección siguen, pero sin
    /// sincronizar; al terminar la ruta se pedirá iniciar sesión otra vez. Se avisa una sola vez.
    static func expiredRouteContinues() -> AudioMessage {
        AudioMessage(
            text: "Tu sesión expiró. La ruta continúa, pero no se guarda en tu cuenta. Al terminar, vuelve a iniciar sesión.",
            priority: .routeInformation,
            contextID: context,
            deduplicationKey: "session-expired"
        )
    }
}
