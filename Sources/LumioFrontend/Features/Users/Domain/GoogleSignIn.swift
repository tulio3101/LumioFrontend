import Foundation

/// Iniciar sesión con Google (SCRUM-62). El teléfono obtiene un ID token de Google y el
/// backend lo verifica (firma, emisor, vigencia y client ID) en POST /users/login/google, o en
/// POST /users/me/google para asociarlo a la cuenta con sesión iniciada.

/// ID token de Google. El correo se lee del token sin verificarlo: solo sirve para recordar
/// qué cuenta usa el teléfono (historial pendiente); quien decide es el backend.
struct GoogleIDToken: Equatable, Sendable {
    let value: String
    let email: String?

    init(value: String, email: String? = nil) {
        self.value = value
        self.email = email ?? Self.email(fromJWT: value)
    }

    /// Lee el claim `email` del payload (segundo segmento, base64url) sin validar la firma.
    static func email(fromJWT token: String) -> String? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = claims["email"] as? String, !email.isEmpty
        else { return nil }
        return email
    }
}

/// Abre la pantalla de Google y devuelve el ID token. Lanza `GoogleSignInFailure.cancelled`
/// si la persona cierra la pantalla sin terminar.
protocol GoogleIDTokenProviding {
    func requestIDToken() async throws -> GoogleIDToken
}

/// Por qué no se pudo iniciar sesión con Google o asociar la cuenta. Ninguno deja una
/// sesión a medias: los tokens solo se guardan si todo salió bien.
enum GoogleSignInFailure: Error, Equatable {
    /// La persona cerró la pantalla de Google.
    case cancelled
    /// Sin red, antes de abrir Google o al hablar con Google o con Lumio.
    case offline
    /// El correo ya es de una cuenta de Lumio con contraseña (409 google_account_conflict).
    case accountConflict
    /// El backend no aceptó el token o la cuenta de Google no tiene correo verificado.
    case rejected
    /// Al asociar (409): esa cuenta de Google ya es de otra cuenta de Lumio. Mi cuenta solo
    /// ofrece asociar si aún no hay ninguna, así que el otro 409 (google_already_linked) no
    /// debería llegar; si llega, el mensaje también lo cubre.
    case accountInUse
    /// Al asociar: la sesión ya no vale.
    case sessionExpired
    /// Google sin configurar en la app o en el servidor (503), o backend sin configurar.
    case unavailable
    /// Cualquier otro error del servidor o de Google.
    case server

    /// Traduce cualquier error del flujo. Los ya traducidos pasan tal cual.
    static func from(_ error: Error) -> GoogleSignInFailure {
        switch error {
        case let failure as GoogleSignInFailure:
            return failure
        case FeatureUnavailable.authentication:
            return .unavailable
        case AuthenticationError.sessionExpired, AuthenticationError.notSignedIn,
             HTTPClientError.statusCode(401):
            return .sessionExpired
        case let error as URLError where error.isConnectivityFailure:
            return .offline
        case let error as URLError where error.code == .cancelled:
            return .cancelled
        default:
            return .server
        }
    }
}

/// Resultado de asociar Google desde Mi cuenta.
enum GoogleLinkOutcome: Equatable {
    case linked(UserProfile)
    case failed(GoogleSignInFailure)
}

// MARK: - Textos

/// Lo que se locuta por el AudioArbiter es lo mismo que se muestra.
enum GoogleSignInAnnouncements {
    static let contextID = "google-sign-in"

    static let linked = "Tu cuenta de Google quedó asociada. Ya puedes iniciar sesión con Google."

    static func message(for failure: GoogleSignInFailure) -> String {
        switch failure {
        case .cancelled:
            "Cancelaste el inicio de sesión con Google. Puedes intentarlo de nuevo o usar tu correo."
        case .offline:
            "Sin conexión. No se pudo continuar con Google. Intenta de nuevo cuando tengas conexión."
        case .accountConflict:
            "Ya existe una cuenta de Lumio con ese correo. Inicia sesión con tu correo y contraseña y "
                + "después asocia Google desde Preferencias, Mi cuenta."
        case .rejected:
            "Google no confirmó tu cuenta. Revisa que tu cuenta de Google tenga el correo verificado "
                + "e intenta de nuevo."
        case .accountInUse:
            "No se pudo asociar: esa cuenta de Google ya está asociada a otra cuenta de Lumio, "
                + "o tu cuenta ya tiene otra cuenta de Google."
        case .sessionExpired:
            ProfileAnnouncements.sessionExpired
        case .unavailable:
            "El inicio de sesión con Google no está disponible por ahora. Usa tu correo y contraseña."
        case .server:
            "No se pudo continuar con Google. Intenta de nuevo en unos momentos."
        }
    }

    /// Título del aviso en pantalla.
    static func title(for failure: GoogleSignInFailure, linking: Bool) -> String {
        switch failure {
        case .cancelled: linking ? "Asociación cancelada" : "Inicio de sesión cancelado"
        case .offline: "Sin conexión"
        default: linking ? "No se asoció tu cuenta de Google" : "No se pudo continuar con Google"
        }
    }
}
