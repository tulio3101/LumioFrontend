import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Finalizar Ruta en el backend. `client` debe ser un AuthorizedHTTPClient.
struct RemoteFinishedRouteService: FinishedRouteSyncing {
    let client: any HTTPClient
    let baseURL: URL?
    var timeout: TimeInterval = 10

    /// POST /places/routes/{id}/finish.
    func finish(remoteID: UUID, outcome: RouteHistoryEntry.Outcome, finishedAt: Date) async throws {
        let path = "places/routes/\(remoteID.uuidString.lowercased())/finish"
        do {
            _ = try await client.send(request(path, body: RouteFinishDTO(status: outcome.rawValue, finishedAt: finishedAt)))
        } catch HTTPClientError.statusCode(404) {
            throw FinishedRouteSyncError.routeNotFound
        }
    }

    /// POST /places/routes/history.
    func record(_ finished: FinishedRoute) async throws {
        do {
            _ = try await client.send(request("places/routes/history", body: FinishedRouteCreateDTO(finished)))
        } catch HTTPClientError.statusCode(409) {
            throw FinishedRouteSyncError.idConflict
        }
    }

    private func request(_ path: String, body: some Encodable) throws -> URLRequest {
        guard let baseURL else { throw RemoteRouteError.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

// Reflejan RouteFinish y FinishedRouteCreate del backend.

struct RouteFinishDTO: Encodable, Equatable {
    let status: String
    let finishedAt: Date

    enum CodingKeys: String, CodingKey {
        case status
        case finishedAt = "finished_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(BackendDate.string(from: finishedAt), forKey: .finishedAt)
    }
}

/// El mismo cuerpo que crear la ruta, más su id del teléfono, cómo terminó y sus fechas.
struct FinishedRouteCreateDTO: Encodable, Equatable {
    let route: RouteCreateDTO
    let id: UUID
    let status: String
    let startedAt: Date
    let finishedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, status
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    init(_ finished: FinishedRoute) {
        route = RouteCreateDTO(finished.route)
        id = finished.route.id
        status = finished.outcome.rawValue
        startedAt = finished.route.createdAt
        finishedAt = finished.finishedAt
    }

    func encode(to encoder: Encoder) throws {
        try route.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(status, forKey: .status)
        try container.encode(BackendDate.string(from: startedAt), forKey: .startedAt)
        try container.encode(BackendDate.string(from: finishedAt), forKey: .finishedAt)
    }
}
