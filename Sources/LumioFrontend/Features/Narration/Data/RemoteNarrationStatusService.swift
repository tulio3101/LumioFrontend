import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SCRUM-41: `GET /vision/status`. No lleva sesión ni foto: el backend responde si el VLM está
/// configurado y si no viene fallando, sin gastar cupo. Sin LumioAPIBaseURL no hay narración.
final class RemoteNarrationStatusService: NarrationStatusChecking, @unchecked Sendable {
    private let client: any HTTPClient
    private let baseURL: URL?
    private let timeout: TimeInterval

    init(client: any HTTPClient, baseURL: URL?, timeout: TimeInterval = 4) {
        self.client = client
        self.baseURL = baseURL
        self.timeout = timeout
    }

    func checkStatus() async -> NarrationServiceStatus {
        guard let baseURL else { return .unavailable(retryAfter: nil) }
        var request = URLRequest(
            url: baseURL.appendingPathComponent("vision").appendingPathComponent("status"),
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let data = try await client.send(request)
            let status = try JSONDecoder().decode(NarrationStatusDTO.self, from: data)
            return status.available
                ? .available
                : .unavailable(retryAfter: status.retryAfterSeconds.map { TimeInterval($0) })
        } catch HTTPClientError.statusCode(404) {
            // Un backend anterior a SCRUM-41 no tiene /vision/status: respondió, así que se
            // intenta la narración y sus propias fallas dirán si funciona.
            return .available
        } catch let error as URLError where error.isConnectivityFailure {
            return .unreachable
        } catch {
            // 5xx, respuesta ilegible u otra falla del servidor: no hay narración por ahora.
            return .unavailable(retryAfter: nil)
        }
    }
}

struct NarrationStatusDTO: Decodable, Equatable {
    let available: Bool
    let reason: String
    let retryAfterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case available
        case reason
        case retryAfterSeconds = "retry_after_seconds"
    }
}
