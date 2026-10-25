import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Inyectar URLSessionHTTPClient en servicios remotos; no llamar desde una View.
protocol HTTPClient {
    func send(_ request: URLRequest) async throws -> Data
}

enum HTTPClientError: Error {
    case invalidResponse
    case statusCode(Int)
}

struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPClientError.statusCode(http.statusCode)
        }
        return data
    }
}
