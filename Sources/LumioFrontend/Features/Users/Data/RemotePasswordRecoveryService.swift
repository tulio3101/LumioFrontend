import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// POST /users/password-reset y /users/password-reset/confirm. No usan access token: quien
/// recupera la contraseña no tiene sesión. Sin LumioAPIBaseURL: FeatureUnavailable.
struct RemotePasswordRecoveryService: PasswordRecoveryRemoting {
    let client: any HTTPClient
    let baseURL: URL?
    var timeout: TimeInterval = 15

    func requestCode(email: String) async throws {
        _ = try await client.send(request("users/password-reset", body: PasswordResetRequestDTO(email: email)))
    }

    func resetPassword(email: String, code: String, newPassword: String) async throws {
        let body = PasswordResetConfirmDTO(email: email, code: code, newPassword: newPassword)
        _ = try await client.send(request("users/password-reset/confirm", body: body))
    }

    private func request(_ path: String, body: some Encodable) throws -> URLRequest {
        guard let baseURL else { throw FeatureUnavailable.authentication }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

// Reflejan PasswordResetRequest y PasswordResetConfirm del backend.

struct PasswordResetRequestDTO: Encodable, Equatable {
    let email: String
}

struct PasswordResetConfirmDTO: Encodable, Equatable {
    let email: String
    let code: String
    let newPassword: String

    enum CodingKeys: String, CodingKey {
        case email, code
        case newPassword = "new_password"
    }
}
