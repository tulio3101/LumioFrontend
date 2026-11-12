import Foundation

/// Mensajes de audio de la asistencia de obstáculos. Todos comparten `contextID` para que el
/// AudioArbiter pueda cancelarlos juntos al terminar la navegación (ver SafetyService.stop()).
enum SafetyAudio {
    /// Un único contexto para toda la detección: permite `cancel(contextIDs: ["safety"])`
    /// sin tocar el audio de navegación.
    static let context = "safety"

    /// SCRUM-37 (punto de extensión para Nestor): el modelo YOLO no cargó. Se avisa con
    /// prioridad alta que la detección no está disponible, pero la navegación sigue.
    static func modelUnavailable() -> AudioMessage {
        AudioMessage(
            text: "La detección de obstáculos no está disponible. La navegación sigue funcionando.",
            priority: .immediateRisk,
            contextID: context,
            deduplicationKey: "safety-unavailable"
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
}
