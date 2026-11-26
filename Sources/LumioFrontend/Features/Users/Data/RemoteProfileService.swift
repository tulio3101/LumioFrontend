import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GET y PATCH /users/me y PUT /users/me/password con el access token (AuthorizedHTTPClient
/// renueva la sesión si hace falta). Sin LumioAPIBaseURL configurada: FeatureUnavailable.
struct RemoteProfileService: ProfileRemoting {
    let client: any HTTPClient
    let baseURL: URL?
    var timeout: TimeInterval = 15

    func loadProfile() async throws -> UserProfile {
        let data = try await client.send(request("users/me", method: "GET"))
        return try JSONDecoder().decode(UserReadDTO.self, from: data).profile
    }

    func updateProfile(_ changes: ProfileChanges) async throws -> UserProfile {
        let body = ProfileUpdateDTO(displayName: changes.displayName, phone: changes.phone)
        let data = try await client.send(request("users/me", method: "PATCH", body: body))
        return try JSONDecoder().decode(UserReadDTO.self, from: data).profile
    }

    func changePassword(current: String, new: String) async throws {
        let body = PasswordChangeDTO(currentPassword: current, newPassword: new)
        _ = try await client.send(request("users/me/password", method: "PUT", body: body))
    }

    /// 403: Lumio no aceptó el token de Google. 409: esa cuenta de Google ya es de otra
    /// cuenta de Lumio (o esta ya tiene otra). 503: Google no disponible en el servidor.
    func linkGoogle(idToken: String) async throws -> UserProfile {
        do {
            let data = try await client.send(
                request("users/me/google", method: "POST", body: GoogleTokenDTO(idToken: idToken))
            )
            return try JSONDecoder().decode(UserReadDTO.self, from: data).profile
        } catch HTTPClientError.statusCode(403) {
            throw GoogleSignInFailure.rejected
        } catch HTTPClientError.statusCode(409) {
            throw GoogleSignInFailure.accountInUse
        } catch HTTPClientError.statusCode(503) {
            throw GoogleSignInFailure.unavailable
        }
    }

    private func request(_ path: String, method: String) throws -> URLRequest {
        guard let baseURL else { throw FeatureUnavailable.authentication }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func request(_ path: String, method: String, body: some Encodable) throws -> URLRequest {
        var request = try self.request(path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

// Reflejan UserRead, UserProfileUpdate y PasswordChange del backend.

struct UserReadDTO: Decodable, Equatable {
    let id: UUID
    let email: String
    let displayName: String?
    let phone: String?
    /// Opcional: un backend anterior a SCRUM-62 no lo envía.
    let googleLinked: Bool?

    enum CodingKeys: String, CodingKey {
        case id, email, phone
        case displayName = "display_name"
        case googleLinked = "google_linked"
    }

    var profile: UserProfile {
        UserProfile(
            id: id, email: email, displayName: displayName, phone: phone,
            googleLinked: googleLinked ?? false
        )
    }
}

/// Envía siempre los dos campos: `null` quita el dato.
struct ProfileUpdateDTO: Encodable, Equatable {
    let displayName: String?
    let phone: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case phone
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(phone, forKey: .phone)
    }
}

struct PasswordChangeDTO: Encodable, Equatable {
    let currentPassword: String
    let newPassword: String

    enum CodingKeys: String, CodingKey {
        case currentPassword = "current_password"
        case newPassword = "new_password"
    }
}
