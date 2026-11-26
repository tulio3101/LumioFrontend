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

    /// SCRUM-33: sin LiDAR no se detectan desniveles (escalones/escaleras). Se avisa una sola vez.
    static func elevationUnavailable() -> AudioMessage {
        AudioMessage(
            text: "No puedo detectar desniveles sin sensor de profundidad.",
            priority: .environmentInformation,
            contextID: context,
            deduplicationKey: "safety-no-elevation"
        )
    }

    /// SCRUM-321: calor crítico. La detección se pausa para enfriar el teléfono; se avisa una vez.
    static func thermalPaused() -> AudioMessage {
        AudioMessage(
            text: "El teléfono se está calentando. Pauso la detección un momento.",
            priority: .immediateRisk,
            contextID: context,
            deduplicationKey: "safety-thermal-paused"
        )
    }

    /// SCRUM-321: el teléfono enfrió y la detección se reanuda. Se avisa una vez.
    static func thermalResumed() -> AudioMessage {
        AudioMessage(
            text: "Detección reanudada.",
            priority: .routeInformation,
            contextID: context,
            deduplicationKey: "safety-thermal-resumed"
        )
    }

    /// SCRUM-314: «cámara lista». Se dice una vez por ruta, con la primera inferencia válida
    /// (la capa de seguridad ya funciona), junto con el modo (SCRUM-320/349) y con vibración
    /// (`HapticCue.safetyReady`). P2: el usuario tiene que oírlo antes de confiar en la
    /// detección, pero una alerta P1 lo interrumpe. Vence a los 15 s: tarde ya no sirve.
    static let readyPrefix = "Cámara lista. La detección de obstáculos está activa."

    /// SCRUM-349: modo reducido (sin LiDAR), avisos de distancia aproximados.
    static func reducedMode(now: Date = Date()) -> AudioMessage {
        AudioMessage(
            text: readyPrefix + " Modo reducido: los avisos de distancia son aproximados y de corto alcance.",
            priority: .routeInformation,
            createdAt: now,
            expiresAt: now.addingTimeInterval(15),
            contextID: context,
            deduplicationKey: "safety-mode-reduced"
        )
    }

    /// SCRUM-320: modo completo (con LiDAR), distancias exactas. Se anuncia una vez al iniciar.
    static func fullMode(now: Date = Date()) -> AudioMessage {
        AudioMessage(
            text: readyPrefix + " Modo completo: las distancias a los obstáculos son exactas.",
            priority: .routeInformation,
            createdAt: now,
            expiresAt: now.addingTimeInterval(15),
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
