import Foundation

/// Mensajes de audio de la asistencia de obstáculos. Todos comparten `contextID` para que el
/// AudioArbiter pueda cancelarlos juntos al terminar la navegación (ver SafetyService.stop()).
enum SafetyAudio {
    /// Un único contexto para toda la detección: permite `cancel(contextIDs: ["safety"])`
    /// sin tocar el audio de navegación.
    static let context = "safety"

    /// SCRUM-37: se perdió la detección (modelo ausente, carga/inferencia fallida o captura
    /// interrumpida). P1 una sola vez por episodio de fallo; la navegación sigue.
    static func modelUnavailable() -> AudioMessage {
        AudioMessage(
            text: "La detección de obstáculos no está disponible. La navegación sigue funcionando.",
            priority: .immediateRisk,
            contextID: context,
            deduplicationKey: "safety-unavailable"
        )
    }

    /// SCRUM-37: la detección volvió tras un fallo (solo después de una inferencia válida).
    /// P2 con vencimiento: si se retrasa por otros avisos, ya no se reproduce.
    static func detectionRecovered(now: Date = Date()) -> AudioMessage {
        AudioMessage(
            text: "La detección de obstáculos vuelve a estar disponible.",
            priority: .routeInformation,
            expiresAt: now.addingTimeInterval(10),
            contextID: context,
            deduplicationKey: "safety-recovered"
        )
    }

    /// SCRUM-315: sin permiso de cámara la ruta continúa sin detección. Se anuncia una sola vez.
    static func cameraUnavailable() -> AudioMessage {
        AudioMessage(
            text: "La navegación continúa sin detección de obstáculos porque la cámara no tiene permiso.",
            priority: .environmentInformation,
            contextID: context,
            deduplicationKey: "safety-no-camera"
        )
    }

    /// SCRUM-349: modo reducido (sin LiDAR), avisos de distancia aproximados.
    static func reducedMode() -> AudioMessage {
        AudioMessage(
            text: "Modo reducido. Los avisos de distancia son aproximados y de corto alcance.",
            priority: .environmentInformation,
            contextID: context,
            deduplicationKey: "safety-mode-reduced"
        )
    }

    /// SCRUM-320: modo completo (con LiDAR), distancias exactas. Se anuncia una vez al iniciar.
    static func fullMode() -> AudioMessage {
        AudioMessage(
            text: "Modo completo. Las distancias a los obstáculos son exactas.",
            priority: .environmentInformation,
            contextID: context,
            deduplicationKey: "safety-mode-full"
        )
    }

    /// SCRUM-33: la cámara apunta demasiado al piso. Se pide levantar el teléfono.
    static func raisePhone() -> AudioMessage {
        AudioMessage(
            text: "Levanta el teléfono para detectar mejor lo que tienes delante.",
            priority: .environmentInformation,
            contextID: context,
            deduplicationKey: "safety-pitch-raise"
        )
    }

    /// SCRUM-33: la cámara apunta demasiado al cielo. Se pide bajar el teléfono.
    static func lowerPhone() -> AudioMessage {
        AudioMessage(
            text: "Baja el teléfono para detectar mejor lo que tienes delante.",
            priority: .environmentInformation,
            contextID: context,
            deduplicationKey: "safety-pitch-lower"
        )
    }
}
