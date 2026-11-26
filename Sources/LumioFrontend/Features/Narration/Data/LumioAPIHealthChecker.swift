import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Health check a `LumioAPIBaseURL`. Sin URL, o si la red no llega, no está alcanzable.
final class LumioAPIHealthChecker: EndpointHealthChecking, @unchecked Sendable {
    private let client: any HTTPClient
    private let baseURL: URL?
    private let timeout: TimeInterval

    init(client: any HTTPClient, baseURL: URL?, timeout: TimeInterval = 4) {
        self.client = client
        self.baseURL = baseURL
        self.timeout = timeout
    }

    func isReachable() async -> Bool {
        guard let baseURL else { return false }
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        do {
            _ = try await client.send(request)
            return true
        } catch let error as HTTPClientError {
            // El servidor contestó (4xx/5xx o respuesta rara): hay API, aunque falle el GET.
            switch error {
            case .statusCode, .invalidResponse: return true
            }
        } catch let error as URLError {
            return !error.isConnectivityFailure
        } catch {
            return false
        }
    }
}
