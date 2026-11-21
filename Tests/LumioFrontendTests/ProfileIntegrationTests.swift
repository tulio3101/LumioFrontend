import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

/// Personalizar Cuenta integrado: AudioArbiter real y cliente del backend con sesión
/// (Bearer y refresh) sobre /users/me.

private let tokenPair = Data("""
{"access_token":"access-2","refresh_token":"refresh-2","token_type":"bearer","expires_in":900}
""".utf8)

private func userRead(name: String?, phone: String?) -> Data {
    let encode = { (value: String?) in value.map { "\"\($0)\"" } ?? "null" }
    return Data("""
    {"id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","email":"ana@example.com",
    "display_name":\(encode(name)),"phone":\(encode(phone)),"created_at":"2026-11-20T10:00:00Z"}
    """.utf8)
}

@MainActor
private struct ProfileFlow {
    let player = FakeAudioPlayer()
    let arbiter: AudioArbiterService
    let http: FakeHTTPClient
    let tokens = InMemoryTokenStore(AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
    let service: ProfileService

    init(backend: Result<Data, Error>) {
        arbiter = AudioArbiterService(player: player)
        http = FakeHTTPClient(response: backend)
        let baseURL = URL(string: "http://localhost:8000")!
        let authorized = AuthorizedHTTPClient(
            base: http, api: AuthAPI(client: http, baseURL: baseURL), store: tokens
        )
        service = ProfileService(
            remote: RemoteProfileService(client: authorized, baseURL: baseURL), tokens: tokens, arbiter: arbiter
        )
    }

    var spoken: String? { arbiter.currentMessage?.text }
}

@Test @MainActor func profileIsLoadedEditedAndSavedWithTheSession() async throws {
    let flow = ProfileFlow(backend: .success(userRead(name: nil, phone: nil)))

    let loaded = try await flow.service.loadProfile().get()
    #expect(loaded.email == "ana@example.com")
    #expect(loaded.displayName == nil)

    flow.http.response = .success(userRead(name: "Ana María", phone: "3001234567"))
    let outcome = await flow.service.saveProfile(displayName: "Ana  María", phone: "300 123 4567")

    guard case .saved(let saved) = outcome else {
        Issue.record("Se esperaba .saved, llegó \(outcome)")
        return
    }
    #expect(saved.displayName == "Ana María")
    #expect(flow.http.requests.map(\.httpMethod) == ["GET", "PATCH"])
    #expect(flow.http.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-1" })
    let body = try #require(flow.http.requests.last?.httpBody)
    let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(sent == ["display_name": "Ana María", "phone": "3001234567"])
    #expect(flow.spoken == "Cambios guardados.")
}

@Test @MainActor func invalidDataNeverReachesTheBackend() async throws {
    let flow = ProfileFlow(backend: .success(userRead(name: nil, phone: nil)))
    _ = await flow.service.loadProfile()

    let outcome = await flow.service.saveProfile(displayName: "Ana", phone: "12345")

    #expect(outcome == .invalid(ProfileValidation(displayName: nil, phone: .invalid)))
    #expect(flow.http.requests.map(\.httpMethod) == ["GET"])
    #expect(flow.spoken == "Revisa los datos. El celular debe tener 10 dígitos y empezar por 3.")
}

@Test @MainActor func expiredAccessTokenIsRenewedBeforeSaving() async throws {
    let flow = ProfileFlow(backend: .success(userRead(name: nil, phone: nil)))
    _ = await flow.service.loadProfile()
    flow.http.queued = [.failure(HTTPClientError.statusCode(401)), .success(tokenPair)]
    flow.http.response = .success(userRead(name: "Ana", phone: nil))

    let outcome = await flow.service.saveProfile(displayName: "Ana", phone: "")

    #expect(outcome == .saved(UserProfile(
        id: UUID(uuidString: "6f9619ff-8b86-d011-b42d-00c04fc964ff")!, email: "ana@example.com",
        displayName: "Ana", phone: nil
    )))
    #expect(flow.http.requests.map { $0.url?.path } == ["/users/me", "/users/me", "/users/refresh", "/users/me"])
    #expect(flow.http.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
}

@Test @MainActor func rejectedSessionClearsTokensAndIsSpoken() async {
    let flow = ProfileFlow(backend: .failure(HTTPClientError.statusCode(401)))

    let result = await flow.service.loadProfile()

    #expect(result == .failure(.sessionExpired))
    #expect(flow.tokens.load() == nil)
    #expect(flow.spoken == "Tu sesión expiró. Inicia sesión de nuevo.")
}

@Test @MainActor func serverErrorKeepsTheProfileAndIsSpoken() async throws {
    let flow = ProfileFlow(backend: .success(userRead(name: "Ana", phone: nil)))
    _ = await flow.service.loadProfile()
    flow.http.response = .failure(HTTPClientError.statusCode(500))

    let outcome = await flow.service.saveProfile(displayName: "Luis", phone: "")

    #expect(outcome == .failed(.server))
    #expect(flow.service.current?.displayName == "Ana")
    #expect(flow.spoken?.contains("Tus datos siguen como estaban.") == true)
}

@Test @MainActor func passwordChangeKeepsThisDeviceSignedIn() async throws {
    let flow = ProfileFlow(backend: .success(Data()))

    let outcome = await flow.service.changePassword(
        current: "clave-segura-1", new: "otra-clave-segura", confirmation: "otra-clave-segura"
    )

    #expect(outcome == .changed)
    let request = try #require(flow.http.requests.first)
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.path == "/users/me/password")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    #expect(flow.tokens.load() != nil)
    #expect(flow.spoken == "Contraseña cambiada. Se cerró tu sesión en los demás dispositivos.")
}

@Test @MainActor func wrongCurrentPasswordDoesNotRenewTheSession() async throws {
    let flow = ProfileFlow(backend: .failure(HTTPClientError.statusCode(403)))

    let outcome = await flow.service.changePassword(
        current: "no-es-la-clave", new: "otra-clave-segura", confirmation: "otra-clave-segura"
    )

    #expect(outcome == .failed(.wrongCurrentPassword))
    // 403 no dispara el refresh (un 401 sí lo haría).
    #expect(flow.http.requests.map { $0.url?.path } == ["/users/me/password"])
    #expect(flow.tokens.load() != nil)
    #expect(flow.spoken == "La contraseña actual no es correcta. No se cambió la contraseña.")
}

@Test @MainActor func offlinePasswordChangeIsSpoken() async {
    let flow = ProfileFlow(backend: .failure(URLError(.notConnectedToInternet)))

    let outcome = await flow.service.changePassword(
        current: "clave-segura-1", new: "otra-clave-segura", confirmation: "otra-clave-segura"
    )

    #expect(outcome == .failed(.offline))
    #expect(flow.spoken == "Sin conexión. No se pudo cambiar la contraseña. Intenta de nuevo cuando tengas conexión.")
}
