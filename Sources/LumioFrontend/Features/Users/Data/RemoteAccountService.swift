import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// DELETE /users/me con el access token (AuthorizedHTTPClient renueva la sesión si hace
/// falta). Sin LumioAPIBaseURL configurada no hay backend: FeatureUnavailable.
struct RemoteAccountService: AccountRemoving {
    let client: any HTTPClient
    let baseURL: URL?
    var timeout: TimeInterval = 15

    func deleteAccount() async throws {
        guard let baseURL else { throw FeatureUnavailable.authentication }
        var request = URLRequest(url: baseURL.appendingPathComponent("users/me"), timeoutInterval: timeout)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try await client.send(request)
    }
}
