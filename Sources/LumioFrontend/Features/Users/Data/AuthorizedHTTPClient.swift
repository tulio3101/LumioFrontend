import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTPClient que añade `Authorization: Bearer <access_token>`. Si el backend responde 401,
/// renueva los tokens una sola vez (aunque fallen varias peticiones a la vez) y repite la
/// petición. Si el refresh token ya no vale, borra la sesión y lanza `sessionExpired`.
actor AuthorizedHTTPClient: HTTPClient {
    private let base: any HTTPClient
    private let api: AuthAPI
    private let store: any TokenStoring
    private var refreshing: Task<AuthTokens, Error>?

    init(base: any HTTPClient, api: AuthAPI, store: any TokenStoring) {
        self.base = base
        self.api = api
        self.store = store
    }

    func send(_ request: URLRequest) async throws -> Data {
        guard let tokens = store.load() else { throw AuthenticationError.notSignedIn }
        do {
            return try await base.send(Self.authorized(request, with: tokens))
        } catch HTTPClientError.statusCode(401) {
            let renewed = try await renew(after: tokens)
            return try await base.send(Self.authorized(request, with: renewed))
        }
    }

    private func renew(after rejected: AuthTokens) async throws -> AuthTokens {
        // Otra petición ya renovó la sesión mientras esta esperaba.
        if let current = store.load(), current != rejected { return current }
        if let refreshing { return try await refreshing.value }

        let task = Task { [api] in try await api.refresh(rejected.refreshToken) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let renewed = try await task.value
            try? store.save(renewed)
            return renewed
        } catch AuthenticationError.sessionExpired {
            store.clear()
            // SCRUM-360: avisar para desmontar la ruta activa (detección, monitores, audio) igual
            // que en un cierre de sesión, y devolver la UI al login.
            NotificationCenter.default.post(name: .lumioSessionExpired, object: nil)
            throw AuthenticationError.sessionExpired
        }
    }

    private static func authorized(_ request: URLRequest, with tokens: AuthTokens) -> URLRequest {
        var request = request
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}
