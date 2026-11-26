import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Endpoints de /users que no requieren access token. Traduce los códigos HTTP del
/// backend a AuthenticationError; el resto de errores se propagan tal cual.
struct AuthAPI: @unchecked Sendable {
    let client: any HTTPClient
    let baseURL: URL
    var timeout: TimeInterval = 10

    /// POST /users. No inicia sesión: el backend no devuelve tokens al registrar.
    func register(email: String, password: String) async throws {
        do {
            _ = try await client.send(request("users", body: CredentialsDTO(email: email, password: password)))
        } catch HTTPClientError.statusCode(409) {
            throw AuthenticationError.emailAlreadyRegistered
        }
    }

    /// POST /users/login.
    func login(email: String, password: String) async throws -> AuthTokens {
        do {
            let data = try await client.send(
                request("users/login", body: CredentialsDTO(email: email, password: password))
            )
            return try Self.tokens(from: data)
        } catch HTTPClientError.statusCode(401) {
            throw AuthenticationError.invalidCredentials
        }
    }

    /// POST /users/login/google con el ID token de Google. Entra o crea la cuenta (sin
    /// contraseña) según el identificador de Google; el backend verifica el token.
    func loginWithGoogle(idToken: String) async throws -> AuthTokens {
        do {
            let data = try await client.send(request("users/login/google", body: GoogleTokenDTO(idToken: idToken)))
            return try Self.tokens(from: data)
        } catch HTTPClientError.statusCode(401) {
            throw GoogleSignInFailure.rejected
        } catch HTTPClientError.statusCode(409) {
            throw GoogleSignInFailure.accountConflict
        } catch HTTPClientError.statusCode(503) {
            throw GoogleSignInFailure.unavailable
        }
    }

    /// POST /users/refresh. Rota la sesión: el refresh token usado deja de valer.
    func refresh(_ refreshToken: String) async throws -> AuthTokens {
        do {
            let data = try await client.send(request("users/refresh", body: RefreshDTO(refreshToken: refreshToken)))
            return try Self.tokens(from: data)
        } catch HTTPClientError.statusCode(401) {
            throw AuthenticationError.sessionExpired
        }
    }

    /// POST /users/logout.
    func logout(_ refreshToken: String) async throws {
        _ = try await client.send(request("users/logout", body: RefreshDTO(refreshToken: refreshToken)))
    }

    private func request(_ path: String, body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func tokens(from data: Data) throws -> AuthTokens {
        let pair = try JSONDecoder().decode(TokenPairDTO.self, from: data)
        return AuthTokens(accessToken: pair.accessToken, refreshToken: pair.refreshToken)
    }
}

// Reflejan UserCreate/UserLogin, RefreshRequest y TokenPair del backend.

struct CredentialsDTO: Encodable, Equatable {
    let email: String
    let password: String
}

/// GoogleAuthRequest del backend (iniciar sesión y asociar).
struct GoogleTokenDTO: Encodable, Equatable {
    let idToken: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
    }
}

struct RefreshDTO: Encodable, Equatable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

struct TokenPairDTO: Decodable, Equatable {
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}
