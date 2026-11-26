import Foundation

/// Compuerta de la asistencia de obstáculos (SCRUM-315 / SCRUM-33): prepara el permiso de
/// cámara antes de arrancar la detección y avisa cuando la ruta va sin ella. Nunca bloquea la
/// navegación: si no hay permiso, la ruta sigue y solo cambia que no habrá detección.
@MainActor
protocol CameraAssistanceGating: AnyObject {
    /// Prepara la cámara para la detección. Si el permiso está sin pedir, lo solicita con el
    /// flujo accesible (explica por audio y muestra el diálogo del sistema). Devuelve true si
    /// la cámara queda autorizada. No reinicia la ruta; se llama en segundo plano.
    func prepareObstacleAssistance() async -> Bool
    /// Avisa por audio, una sola vez, que la navegación va sin detección por falta de cámara.
    func announceAssistanceUnavailable()
    /// Si no hay SafetyService, avisa por audio que la detección no está disponible. Lo llama
    /// el ViewModel al iniciar la ruta (una vez por ruta), no al abrir la app. SCRUM-37: en la
    /// app SafetyService siempre existe y los fallos del modelo los avisa el propio servicio.
    func announceModelUnavailable()
}

#if os(iOS)
@MainActor
final class ObstacleAssistanceGate: CameraAssistanceGating {
    private let permissions: PermissionsViewModel
    private let audio: any AudioArbitrating
    /// false solo cuando no hay detección configurada. SCRUM-37: los fallos del modelo en
    /// ejecución (ausente, carga, inferencia) los publica y anuncia SafetyService.
    private let modelAvailable: Bool
    private var announcedCameraUnavailable = false

    init(permissions: PermissionsViewModel, audio: any AudioArbitrating, modelAvailable: Bool = true) {
        self.permissions = permissions
        self.audio = audio
        self.modelAvailable = modelAvailable
    }

    func prepareObstacleAssistance() async -> Bool {
        // Reutiliza el flujo accesible de Nestor (PermissionsViewModel / obstacleAssistance):
        // explica por audio y, si está sin pedir, muestra el diálogo del sistema.
        await permissions.requestForObstacleAssistance()
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
#endif
