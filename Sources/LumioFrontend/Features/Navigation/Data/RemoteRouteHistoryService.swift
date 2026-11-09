import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Lee el historial del backend. `client` debe ser un AuthorizedHTTPClient: el backend
/// identifica al usuario con el access token.
struct RemoteRouteHistoryService: RouteHistoryFetching {
    let client: any HTTPClient
    let baseURL: URL?
    var timeout: TimeInterval = 10

    /// GET /places/routes/history?limit=N (Consultar Rutas Recientes).
    func recentHistory(limit: Int) async throws -> [RouteHistoryEntry] {
        guard let baseURL else { throw RemoteRouteError.notConfigured }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("places/routes/history"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else { throw RemoteRouteError.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await client.send(request)
        return try JSONDecoder().decode(RouteHistoryPageDTO.self, from: data).items.compactMap(\.entry)
    }
}

// Reflejan RouteHistoryPage y RouteHistoryItem del backend.

struct RouteHistoryPageDTO: Decodable, Equatable {
    let items: [RouteHistoryItemDTO]
    let total: Int
}

struct RouteHistoryItemDTO: Decodable, Equatable {
    let destination: PlaceDTO
    let status: String
    let startedAt: String
    let finishedAt: String?

    enum CodingKeys: String, CodingKey {
        case destination, status
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    /// nil si el estado no es de historial o la fecha no se puede leer: se omite esa ruta.
    var entry: RouteHistoryEntry? {
        guard let outcome = RouteHistoryEntry.Outcome(rawValue: status),
              let started = BackendDate.parse(startedAt) else { return nil }
        return RouteHistoryEntry(
            destination: RoutePlace(
                name: destination.name,
                coordinate: GeoCoordinate(latitude: destination.latitude, longitude: destination.longitude)
            ),
            outcome: outcome,
            startedAt: started,
            finishedAt: finishedAt.flatMap(BackendDate.parse)
        )
    }
}

/// Fechas ISO-8601 del backend (Pydantic): con `Z` o `+00:00` y con fracciones de hasta
/// microsegundos, que ISO8601DateFormatter no siempre acepta.
enum BackendDate {
    static func parse(_ text: String) -> Date? {
        var base = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let afterDot = text[text.index(after: dot)...]
            let digits = afterDot.prefix { $0.isNumber }
            fraction = Double("0." + digits) ?? 0
            base = String(text[..<dot]) + String(afterDot.dropFirst(digits.count))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: base)?.addingTimeInterval(fraction)
    }
}
