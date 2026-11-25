import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// POST /sos con el access token (AuthorizedHTTPClient renueva la sesión si hace falta). Sin
/// LumioAPIBaseURL configurada: FeatureUnavailable.
struct RemoteEmergencyService: EmergencyRemoting {
    let client: any HTTPClient
    let baseURL: URL?
    /// Más holgado que el resto: el backend envía un correo por contacto antes de responder.
    var timeout: TimeInterval = 30

    func send(_ alert: EmergencyAlert) async throws -> EmergencyDelivery {
        guard let baseURL else { throw FeatureUnavailable.authentication }
        var request = URLRequest(url: baseURL.appendingPathComponent("sos"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SosRequestDTO(alert))
        let data = try await client.send(request)
        return try JSONDecoder().decode(SosReadDTO.self, from: data).delivery
    }
}

// Reflejan SosRequest y SosRead del backend.

/// Sin ubicación se omiten los tres campos: el backend los acepta juntos o ninguno.
struct SosRequestDTO: Encodable, Equatable {
    let idempotencyKey: String
    let latitude: Double?
    let longitude: Double?
    let accuracyM: Double?

    init(_ alert: EmergencyAlert) {
        // El backend escribe los UUID en minúsculas.
        idempotencyKey = alert.idempotencyKey.uuidString.lowercased()
        latitude = alert.location?.latitude
        longitude = alert.location?.longitude
        accuracyM = alert.location?.accuracyMeters
    }

    enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case latitude, longitude
        case accuracyM = "accuracy_m"
    }
}

struct SosReadDTO: Decodable, Equatable {
    let contactsTotal: Int
    let contactsSent: Int
    let locationIncluded: Bool

    enum CodingKeys: String, CodingKey {
        case contactsTotal = "contacts_total"
        case contactsSent = "contacts_sent"
        case locationIncluded = "location_included"
    }

    var delivery: EmergencyDelivery {
        EmergencyDelivery(
            contactsTotal: contactsTotal, contactsSent: contactsSent, locationIncluded: locationIncluded
        )
    }
}
