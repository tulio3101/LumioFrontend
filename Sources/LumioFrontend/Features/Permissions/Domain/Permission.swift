import Foundation

enum AppPermission: String, CaseIterable, Identifiable {
    case microphone, speechRecognition, location, camera, notifications
    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Micrófono"
        case .speechRecognition: return "Reconocimiento de voz"
        case .location: return "Ubicación"
        case .camera: return "Cámara"
        case .notifications: return "Notificaciones"
        }
    }

    var purpose: String {
        switch self {
        case .microphone: return "Lumio necesita el micrófono para escuchar el destino que indiques hablando."
        case .speechRecognition: return "Lumio necesita reconocimiento de voz para convertir lo que dices en el texto de tu destino."
        case .location: return "Lumio necesita tu ubicación mientras usas la app para calcular la ruta desde donde estás y guiarte."
        case .camera: return "Lumio necesita la cámara para detectar obstáculos durante la asistencia."
        case .notifications: return "Las notificaciones permiten recibir avisos de Lumio cuando una función los utilice. Son opcionales para crear una ruta."
        }
    }

    var limitation: String {
        switch self {
        case .microphone: return "No puedes indicar ni modificar tu destino por voz sin acceso al micrófono."
        case .speechRecognition: return "No puedes transcribir ni confirmar tu destino por voz sin reconocimiento de voz."
        case .location: return "No puedes calcular una ruta desde tu posición actual sin acceso a tu ubicación."
        case .camera: return "La detección de obstáculos no está disponible sin acceso a la cámara."
        case .notifications: return "No recibirás los avisos que utilicen notificaciones. Puedes crear rutas sin este permiso."
        }
    }
}

enum PermissionStatus: Equatable {
    case notDetermined, authorized, denied, restricted, unavailable

    var label: String {
        switch self {
        case .notDetermined: return "Sin solicitar"
        case .authorized: return "Permitido"
        case .denied: return "Denegado"
        case .restricted: return "Restringido por el dispositivo"
        case .unavailable: return "Servicio no disponible"
        }
    }
}

enum PermissionPurpose {
    case voiceDestination, route, obstacleAssistance
    var required: [AppPermission] {
        switch self {
        case .voiceDestination: return [.microphone, .speechRecognition]
        case .route: return [.location]
        case .obstacleAssistance: return [.camera]
        }
    }
}

@MainActor
protocol PermissionProviding: AnyObject {
    func status(for permission: AppPermission) async -> PermissionStatus
    func request(_ permission: AppPermission) async throws -> PermissionStatus
}

/// Consultar al entrar a una función y al volver de Ajustes. No guarda autorizaciones en disco.
@MainActor
final class PermissionService {
    private let provider: any PermissionProviding
    private var requesting = false
    init(provider: any PermissionProviding) { self.provider = provider }

    func statuses() async -> [AppPermission: PermissionStatus] {
        var result: [AppPermission: PermissionStatus] = [:]
        for permission in AppPermission.allCases {
            result[permission] = await provider.status(for: permission)
        }
        return result
    }

    func missing(for purpose: PermissionPurpose) async -> [AppPermission] {
        var result: [AppPermission] = []
        for permission in purpose.required {
            if await provider.status(for: permission) != .authorized { result.append(permission) }
        }
        return result
    }

    func request(_ permission: AppPermission) async throws -> PermissionStatus {
        guard !requesting else { throw PermissionRequestError.alreadyRequesting }
        requesting = true
        defer { requesting = false }
        let current = await provider.status(for: permission)
        guard current == .notDetermined else { return current }
        return try await provider.request(permission)
    }
}

enum PermissionRequestError: Error { case alreadyRequesting }
