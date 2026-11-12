import Foundation

/// Compuerta de la asistencia de obstáculos (SCRUM-315): decide si la cámara permite arrancar
/// la detección y avisa una sola vez por sesión cuando la ruta va sin ella. Nunca bloquea la
/// navegación: si no hay permiso, la ruta sigue y solo cambia que no habrá detección.
@MainActor
protocol CameraAssistanceGating: AnyObject {
    /// true si la cámara está autorizada para la asistencia de obstáculos.
    func canAssistWithObstacles() async -> Bool
    /// Avisa por audio, una sola vez, que la navegación va sin detección por falta de cámara.
    func announceAssistanceUnavailable()
    /// Si el modelo YOLO no cargó, avisa por audio que la detección no está disponible. Lo
    /// llama el ViewModel al iniciar la ruta (una vez por ruta), no al abrir la app.
    func announceModelUnavailable()
}

@MainActor
final class ObstacleAssistanceGate: CameraAssistanceGating {
    private let permissions: PermissionService
    private let audio: any AudioArbitrating
    /// SCRUM-37: estado guardado del fallo de carga del modelo. Se decide en AppDependencies.
    private let modelAvailable: Bool
    private var announcedCameraUnavailable = false

    init(permissions: PermissionService, audio: any AudioArbitrating, modelAvailable: Bool = true) {
        self.permissions = permissions
        self.audio = audio
        self.modelAvailable = modelAvailable
    }

    func canAssistWithObstacles() async -> Bool {
        await permissions.missing(for: .obstacleAssistance).isEmpty
    }

    func announceAssistanceUnavailable() {
        guard !announcedCameraUnavailable else { return }
        announcedCameraUnavailable = true
        audio.receive(SafetyAudio.cameraUnavailable())
    }

    func announceModelUnavailable() {
        guard !modelAvailable else { return }
        audio.receive(SafetyAudio.modelUnavailable())
    }
}
