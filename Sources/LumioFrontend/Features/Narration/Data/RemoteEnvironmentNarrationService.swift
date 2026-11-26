import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SCRUM-262: `POST /vision/analyze` con el access token (AuthorizedHTTPClient renueva la
/// sesión si hace falta) y `multipart/form-data` (ADR-308 §6): la foto va como archivo, no en
/// base64 dentro de un JSON. Sin LumioAPIBaseURL configurada: FeatureUnavailable.
struct RemoteEnvironmentNarrationService: EnvironmentDescribing {
    let client: any HTTPClient
    let baseURL: URL?
    /// ADR-308: una sola solicitud en vuelo y timeout del cliente de 5 s.
    var timeout: TimeInterval = 5
    var makeBoundary: () -> String = { "lumio-\(UUID().uuidString)" }

    func describe(
        _ frame: NarrationFrame, trigger: NarrationTrigger, consentVersion: String
    ) async throws -> String {
        guard let baseURL else { throw FeatureUnavailable.authentication }
        let boundary = makeBoundary()
        var request = URLRequest(
            url: baseURL.appendingPathComponent("vision").appendingPathComponent("analyze"),
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Self.multipartBody(
            frame: frame, trigger: trigger, consentVersion: consentVersion, boundary: boundary
        )
        let data = try await client.send(request)
        return try JSONDecoder().decode(VisionAnalysisResponseDTO.self, from: data).text
    }

    static func multipartBody(
        frame: NarrationFrame, trigger: NarrationTrigger, consentVersion: String, boundary: String
    ) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        field("captured_at", formatter.string(from: frame.capturedAt))
        field("trigger", trigger.rawValue)
        field("consent_version", consentVersion)
        field("language", "es")
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"image\"; filename=\"frame.jpg\"\r\n".utf8
        ))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(frame.jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

/// Refleja `VisionAnalysisResponse` del backend. No hay nivel de alerta: un riesgo nunca
/// viene de la red (ADR-308).
struct VisionAnalysisResponseDTO: Decodable, Equatable {
    let text: String
    let model: String
    let latencyMs: Int

    enum CodingKeys: String, CodingKey {
        case text, model
        case latencyMs = "latency_ms"
    }
}
