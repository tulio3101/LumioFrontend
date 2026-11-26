import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SCRUM-25: `/location-shares` con el access token (AuthorizedHTTPClient renueva la sesión si
/// hace falta). Sin LumioAPIBaseURL configurada: FeatureUnavailable.
struct RemoteLocationSharingService: LocationSharingRemoting {
    let client: any HTTPClient
    let baseURL: URL?
    /// Empezar es más lento: el backend envía un correo por contacto antes de responder.
    var startTimeout: TimeInterval = 30
    var updateTimeout: TimeInterval = 10

    func start(at position: SharedPosition, durationMinutes: Int) async throws -> LocationShare {
        var request = try makeRequest("location-shares", method: "POST", timeout: startTimeout)
        request.httpBody = try JSONEncoder().encode(
            LocationShareStartDTO(position: position, durationMinutes: durationMinutes)
        )
        let data = try await client.send(request)
        return try JSONDecoder().decode(LocationShareReadDTO.self, from: data).share()
    }

    func update(_ shareID: UUID, to position: SharedPosition) async throws {
        var request = try makeRequest(
            "location-shares/\(shareID.uuidString.lowercased())/position", method: "PUT",
            timeout: updateTimeout
        )
        request.httpBody = try JSONEncoder().encode(PositionDTO(position))
        _ = try await client.send(request)
    }

    func stop(_ shareID: UUID) async throws {
        let request = try makeRequest(
            "location-shares/\(shareID.uuidString.lowercased())", method: "DELETE",
            timeout: updateTimeout
        )
        _ = try await client.send(request)
    }

    private func makeRequest(_ path: String, method: String, timeout: TimeInterval) throws -> URLRequest {
        guard let baseURL else { throw FeatureUnavailable.authentication }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}

// Reflejan Position, LocationShareStart y LocationShareRead del backend.

struct PositionDTO: Encodable, Equatable {
    let latitude: Double
    let longitude: Double
    let accuracyM: Double?

    init(_ position: SharedPosition) {
        latitude = position.latitude
        longitude = position.longitude
        accuracyM = position.accuracyMeters
    }

    enum CodingKeys: String, CodingKey {
        case latitude, longitude
        case accuracyM = "accuracy_m"
    }
}

struct LocationShareStartDTO: Encodable, Equatable {
    let latitude: Double
    let longitude: Double
    let accuracyM: Double?
    let durationMinutes: Int

    init(position: SharedPosition, durationMinutes: Int) {
        latitude = position.latitude
        longitude = position.longitude
        accuracyM = position.accuracyMeters
        self.durationMinutes = durationMinutes
    }

    enum CodingKeys: String, CodingKey {
        case latitude, longitude
        case accuracyM = "accuracy_m"
        case durationMinutes = "duration_minutes"
    }
}

struct LocationShareReadDTO: Decodable, Equatable {
    let id: UUID
    let expiresAt: String
    let contactsTotal: Int
    let contactsSent: Int

    enum CodingKeys: String, CodingKey {
        case id
        case expiresAt = "expires_at"
        case contactsTotal = "contacts_total"
        case contactsSent = "contacts_sent"
    }

    func share() throws -> LocationShare {
        guard let expires = BackendDate.parse(expiresAt) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.expiresAt], debugDescription: expiresAt))
        }
        return LocationShare(id: id, expiresAt: expires, contactsTotal: contactsTotal, contactsSent: contactsSent)
    }
}
