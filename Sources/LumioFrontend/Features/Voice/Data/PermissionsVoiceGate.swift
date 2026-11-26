#if os(iOS)
import Foundation

/// Reutiliza el flujo accesible de permisos (SCRUM-315): explica por audio para qué sirve
/// cada permiso y luego muestra la solicitud de iOS.
@MainActor
final class PermissionsVoiceGate: VoicePermissionGating {
    private let permissions: PermissionsViewModel

    init(permissions: PermissionsViewModel) {
        self.permissions = permissions
    }

    func prepareVoiceInput() async -> Bool {
        await permissions.requestForVoiceCommands()
    }
}
#endif
