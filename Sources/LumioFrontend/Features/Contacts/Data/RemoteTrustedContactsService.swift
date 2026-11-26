import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GET, POST, PUT y DELETE /contacts con el access token (AuthorizedHTTPClient renueva la
/// sesión si hace falta). Sin LumioAPIBaseURL configurada: FeatureUnavailable.
struct RemoteTrustedContactsService: TrustedContactsRemoting {
    let client: any HTTPClient
    let baseURL: URL?
    var timeout: TimeInterval = 15

    func listContacts() async throws -> [TrustedContact] {
        let data = try await client.send(request("contacts", method: "GET"))
        return try JSONDecoder().decode([TrustedContactDTO].self, from: data).map(\.contact)
    }

    func addContact(_ draft: ContactDraft) async throws -> TrustedContact {
        let body = ContactWriteDTO(name: draft.name, email: draft.email)
        let data = try await client.send(request("contacts", method: "POST", body: body))
        return try JSONDecoder().decode(TrustedContactDTO.self, from: data).contact
    }

    func updateContact(id: UUID, _ draft: ContactDraft) async throws -> TrustedContact {
        let body = ContactWriteDTO(name: draft.name, email: draft.email)
        let data = try await client.send(request(Self.path(for: id), method: "PUT", body: body))
        return try JSONDecoder().decode(TrustedContactDTO.self, from: data).contact
    }

    func deleteContact(id: UUID) async throws {
        _ = try await client.send(request(Self.path(for: id), method: "DELETE"))
    }

    /// El backend escribe los UUID en minúsculas.
    private static func path(for id: UUID) -> String {
        "contacts/" + id.uuidString.lowercased()
    }

    private func request(_ path: String, method: String) throws -> URLRequest {
        guard let baseURL else { throw FeatureUnavailable.authentication }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func request(_ path: String, method: String, body: some Encodable) throws -> URLRequest {
        var request = try self.request(path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

// Reflejan TrustedContactRead y TrustedContactWrite del backend.

struct TrustedContactDTO: Decodable, Equatable {
    let id: UUID
    let name: String
    let email: String

    var contact: TrustedContact {
        TrustedContact(id: id, name: name, email: email)
    }
}

struct ContactWriteDTO: Encodable, Equatable {
    let name: String
    let email: String
}
