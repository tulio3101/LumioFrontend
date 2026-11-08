import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum RemoteRouteError: Error, Equatable {
    /// Falta LumioAPIBaseURL o LumioDevUserID en la configuración.
    case notConfigured
}

/// Persiste la ruta activa en el backend con PUT /places/routes/active.
struct RemoteActiveRouteService: ActiveRouteSyncing {
    /// PROVISIONAL hasta el login: el backend identifica al usuario con este header.
    static let userIDHeader = "X-User-Id"

    let client: any HTTPClient
    let baseURL: URL?
    let userID: UUID?
    var timeout: TimeInterval = 10

    func upload(_ route: ActiveRoute) async throws -> UUID {
        guard let baseURL, let userID else { throw RemoteRouteError.notConfigured }
        var request = URLRequest(
            url: baseURL.appendingPathComponent("places/routes/active"),
            timeoutInterval: timeout
        )
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userID.uuidString, forHTTPHeaderField: Self.userIDHeader)
        request.httpBody = try JSONEncoder().encode(RouteCreateDTO(route))
        let data = try await client.send(request)
        return try JSONDecoder().decode(ActiveRouteResponseDTO.self, from: data).id
    }
}
