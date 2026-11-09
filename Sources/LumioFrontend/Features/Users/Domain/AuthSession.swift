import Foundation

/// Tokens emitidos por POST /users/login y renovados por POST /users/refresh.
/// Solo se guardan en Keychain (TokenStoring), nunca en UserDefaults ni en un ViewModel.
struct AuthTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
}

/// Almacén seguro de los tokens de la sesión.
protocol TokenStoring: Sendable {
    func load() -> AuthTokens?
    func save(_ tokens: AuthTokens) throws
    func clear()
}

enum AuthenticationError: Error, Equatable {
    /// 401 en el login: correo o contraseña incorrectos.
    case invalidCredentials
    /// 409 en el registro.
    case emailAlreadyRegistered
    /// No hay tokens guardados: la petición necesita iniciar sesión.
    case notSignedIn
    /// El refresh token fue rechazado: hay que iniciar sesión otra vez.
    case sessionExpired
    /// Keychain no permitió guardar los tokens.
    case tokenStorageFailed
}

/// Cierra la sesión en el backend (si se puede) y borra los tokens del dispositivo.
protocol SessionEnding {
    func endSession() async
}
