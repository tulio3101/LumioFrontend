import Foundation

/// Pantalla Principal Accesible: lo que la app informa por audio al abrir. Se arma con datos
/// locales (sesión guardada, permisos, modelo de detección y ruta guardada); no usa la red.
struct HomeStatusSnapshot: Equatable {
    var isSignedIn: Bool
    var permissions: [AppPermission: PermissionStatus]
    var safety: SafetyReadiness
    /// Destino de la ruta guardada en el teléfono, si hay una activa.
    var activeRouteDestination: String?
}

/// Si la detección de obstáculos podrá arrancar al iniciar una ruta.
enum SafetyReadiness: Equatable {
    case ready
    case cameraDenied
    case modelMissing
}

/// El modelo de detección viene en la app: sin él, la seguridad no puede arrancar.
protocol SafetyModelChecking {
    func isModelAvailable() -> Bool
}

/// Estados de permisos, solo lectura (no pide nada al abrir la app).
@MainActor
protocol PermissionStatusReading: AnyObject {
    func statuses() async -> [AppPermission: PermissionStatus]
}

extension PermissionService: PermissionStatusReading {}

enum HomeAnnouncements {
    /// Permisos sin los que no se puede crear una ruta ni dictar un destino. La cámara se
    /// informa con la seguridad.
    static let essentialPermissions: [AppPermission] = [.location, .microphone, .speechRecognition]

    static let quickActions = "Toca dos veces con dos dedos para indicar un destino por voz. "
        + "El botón de emergencia está al final de la pantalla y también en las acciones."

    /// Permisos esenciales que el usuario negó o que el teléfono no permite. Los que aún no
    /// se han pedido no se mencionan: se piden con el flujo accesible al usar la función.
    static func blockedPermissions(_ statuses: [AppPermission: PermissionStatus]) -> [AppPermission] {
        essentialPermissions.filter { permission in
            switch statuses[permission] {
            case .denied?, .restricted?, .unavailable?: return true
            case .authorized?, .notDetermined?, nil: return false
            }
        }
    }

    static func welcome(_ status: HomeStatusSnapshot) -> String {
        var parts = ["Lumio listo."]
        parts.append(status.isSignedIn
            ? "Sesión iniciada."
            : "Sin sesión: las rutas no se guardan en el servidor.")

        let blocked = blockedPermissions(status.permissions)
        if blocked.isEmpty {
            parts.append("Permisos en orden.")
        } else {
            let names = list(blocked.map { $0.title.lowercased() })
            parts.append("Falta permiso de \(names). Puedes concederlo en Preferencias, Permisos.")
        }

        switch status.safety {
        case .ready:
            parts.append("Detección de obstáculos lista: se activa al iniciar una ruta.")
        case .cameraDenied:
            parts.append("Detección de obstáculos no disponible: falta permiso de cámara.")
        case .modelMissing:
            parts.append("Detección de obstáculos no disponible en esta versión de Lumio.")
        }

        if let destination = status.activeRouteDestination {
            parts.append("Tienes una ruta activa a \(destination).")
        }
        parts.append(quickActions)
        return parts.joined(separator: " ")
    }

    /// "a", "a y b", "a, b y c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " y " + items[items.count - 1]
        }
    }
}
