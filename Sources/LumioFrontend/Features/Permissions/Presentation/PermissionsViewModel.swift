#if os(iOS)
import SwiftUI

@MainActor
final class PermissionsViewModel: ObservableObject {
    @Published private(set) var statuses: [AppPermission: PermissionStatus] = [:]
    @Published private(set) var isRequesting = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var message = ""
    @Published var selected: AppPermission?
    private let service: PermissionService
    private let audio: AudioArbiterService
    private var offerSpeechAfterMicrophone = false

    init(service: PermissionService, audio: AudioArbiterService) {
        self.service = service
        self.audio = audio
    }

    func refresh() async {
        let previous = statuses
        statuses = await service.statuses()
        let changes = AppPermission.allCases.filter {
            previous[$0] != nil && previous[$0] != statuses[$0]
        }
        if !changes.isEmpty && !isRequesting {
            await say(changes.map { feedback(for: $0) }.joined(separator: " "))
        }
    }

    func prepare(_ permission: AppPermission) async {
        guard !isSpeaking, !isRequesting else { return }
        offerSpeechAfterMicrophone = permission == .microphone || permission == .speechRecognition
        let target: AppPermission = permission == .speechRecognition && statuses[.microphone] != .authorized
            ? .microphone : permission
        guard statuses[target] == .notDetermined else {
            await say(feedback(for: target))
            return
        }
        selected = target
    }

    func explain(_ permission: AppPermission) async {
        await say(permission.purpose + " " + permission.limitation +
            " Activa Continuar para abrir la solicitud de iOS, o Ahora no para volver.")
    }

    func requestSelected() async {
        guard let permission = selected, !isRequesting, !isSpeaking else { return }
        isRequesting = true
        do {
            let status = try await service.request(permission)
            statuses[permission] = status
            selected = nil
            await say(feedback(for: permission))
            if permission == .microphone && status == .authorized && offerSpeechAfterMicrophone,
               statuses[.speechRecognition] == .notDetermined {
                selected = .speechRecognition
            }
            offerSpeechAfterMicrophone = false
        } catch {
            selected = nil
            await say("No se pudo solicitar \(permission.title). Intenta de nuevo desde Permisos.")
        }
        isRequesting = false
    }

    func reportRequirements(_ purpose: PermissionPurpose) async -> Bool {
        let missing = await service.missing(for: purpose)
        guard !missing.isEmpty else { return true }
        await say("Faltan permisos: " + missing.map(\.title).joined(separator: ", ") +
            ". Abre Permisos para escuchar la explicación y concederlos.")
        return false
    }

    func feedback(for permission: AppPermission) -> String {
        switch statuses[permission] ?? .notDetermined {
        case .authorized: return "\(permission.title): permiso concedido."
        case .denied:
            return "\(permission.title): permiso denegado. \(permission.limitation) " +
                "Activa Abrir Ajustes. En los ajustes de Lumio, busca \(permission.title) y permite el acceso. Después vuelve a Lumio."
        case .restricted:
            return "\(permission.title): acceso restringido por la configuración del dispositivo. \(permission.limitation) Puede requerir ayuda de quien administra el dispositivo."
        case .unavailable:
            return "\(permission.title): servicio no disponible. \(permission.limitation) " +
                (permission == .location ? "Comprueba Localización en Ajustes, Privacidad y seguridad." : "Comprueba la disponibilidad del servicio en el dispositivo.")
        case .notDetermined: return "\(permission.title): permiso sin solicitar. \(permission.purpose)"
        }
    }

    func say(_ text: String) async {
        guard !isSpeaking else { return }
        message = text
        isSpeaking = true
        // Mensajes de preparación: P2 no urgente. P1 conserva prioridad e interrumpe.
        _ = await audio.receiveAndWait(AudioMessage(text: text, priority: .routeInformation))
        isSpeaking = false
    }
}
#endif
