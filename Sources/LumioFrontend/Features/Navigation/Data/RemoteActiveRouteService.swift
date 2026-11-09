import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum RemoteRouteError: Error, Equatable {
    /// Falta LumioAPIBaseURL en la configuración.
    case notConfigured
}

/// Persiste la ruta activa en el backend. `client` debe ser un AuthorizedHTTPClient: el
/// backend identifica al usuario con el access token.
struct RemoteActiveRouteService: ActiveRouteSyncing {
    let client: any HTTPClient
    let baseURL: URL?
    var timeout: TimeInterval = 10

    /// PUT /places/routes/active (Crear Ruta).
    func upload(_ route: ActiveRoute) async throws -> UUID {
        let data = try await client.send(request("places/routes/active", body: RouteCreateDTO(route)))
        return try JSONDecoder().decode(ActiveRouteResponseDTO.self, from: data).id
    }

    /// PUT /places/routes/{id}/destination (Modificar Ruta).
    func updateDestination(of route: ActiveRoute, remoteID: UUID) async throws {
        let path = "places/routes/\(remoteID.uuidString.lowercased())/destination"
        do {
            _ = try await client.send(request(path, body: RouteCreateDTO(route)))
        } catch HTTPClientError.statusCode(let code) where code == 404 || code == 409 {
            throw ActiveRouteSyncError.routeNoLongerOpen
        }
    }

    private func request(_ path: String, body: RouteCreateDTO) throws -> URLRequest {
        guard let baseURL else { throw RemoteRouteError.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}
