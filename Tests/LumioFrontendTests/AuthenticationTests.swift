import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

private let baseURL = URL(string: "http://localhost:8000")!
private let signedIn = AuthTokens(accessToken: "access-1", refreshToken: "refresh-1")
private let tokenPair = Data("""
{"access_token":"access-2","refresh_token":"refresh-2","token_type":"bearer","expires_in":900}
""".utf8)
private let credentials = AccountCredentials(email: "ana@example.com", password: "clave-segura-1")

private func jsonBody(_ request: URLRequest?) throws -> [String: String] {
    let body = try #require(request?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
}

// MARK: - API de /users

@Test func loginSendsCredentialsAndReturnsTokens() async throws {
    let http = FakeHTTPClient(response: .success(tokenPair))

    let tokens = try await AuthAPI(client: http, baseURL: baseURL)
        .login(email: credentials.email, password: credentials.password)

    #expect(tokens == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
    let request = try #require(http.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "http://localhost:8000/users/login")
    #expect(try jsonBody(request) == ["email": "ana@example.com", "password": "clave-segura-1"])
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func wrongPasswordIsReportedAsInvalidCredentials() async {
    let http = FakeHTTPClient(response: .failure(HTTPClientError.statusCode(401)))

    await #expect(throws: AuthenticationError.invalidCredentials) {
        try await AuthAPI(client: http, baseURL: baseURL).login(email: "a@b.co", password: "x")
    }
}

@Test func registeredEmailIsReportedAsConflict() async {
    let http = FakeHTTPClient(response: .failure(HTTPClientError.statusCode(409)))

    await #expect(throws: AuthenticationError.emailAlreadyRegistered) {
        try await AuthAPI(client: http, baseURL: baseURL).register(email: "a@b.co", password: "clave-segura")
    }
    #expect(http.requests.first?.url?.path == "/users")
}

@Test func refreshSendsTheRefreshToken() async throws {
    let http = FakeHTTPClient(response: .success(tokenPair))

    _ = try await AuthAPI(client: http, baseURL: baseURL).refresh("refresh-1")

    #expect(http.requests.first?.url?.path == "/users/refresh")
    #expect(try jsonBody(http.requests.first) == ["refresh_token": "refresh-1"])
}

@Test func rejectedRefreshTokenMeansExpiredSession() async {
    let http = FakeHTTPClient(response: .failure(HTTPClientError.statusCode(401)))

    await #expect(throws: AuthenticationError.sessionExpired) {
        try await AuthAPI(client: http, baseURL: baseURL).refresh("refresh-1")
    }
}

// MARK: - Iniciar y cerrar sesión

@Test func signInStoresTokens() async throws {
    let store = InMemoryTokenStore()
    let service = RemoteAuthenticationService(
        api: AuthAPI(client: FakeHTTPClient(response: .success(tokenPair)), baseURL: baseURL), store: store
    )

    try await service.signIn(credentials)

    #expect(store.load() == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
    #expect(StoredSessionService(api: nil, store: store).hasActiveSession())
}

@Test func failedSignInStoresNothing() async {
    let store = InMemoryTokenStore()
    let service = RemoteAuthenticationService(
        api: AuthAPI(client: FakeHTTPClient(response: .failure(HTTPClientError.statusCode(401))), baseURL: baseURL),
        store: store
    )

    await #expect(throws: AuthenticationError.invalidCredentials) { try await service.signIn(credentials) }
    #expect(store.load() == nil)
}

@Test func keychainFailureIsReported() async {
    let store = InMemoryTokenStore()
    store.failSave = true
    let service = RemoteAuthenticationService(
        api: AuthAPI(client: FakeHTTPClient(response: .success(tokenPair)), baseURL: baseURL), store: store
    )

    await #expect(throws: AuthenticationError.tokenStorageFailed) { try await service.signIn(credentials) }
}

@Test func withoutBackendOrGoogleAuthenticationIsUnavailable() async {
    let unconfigured = RemoteAuthenticationService(api: nil, store: InMemoryTokenStore())

    await #expect(throws: FeatureUnavailable.self) { try await unconfigured.signIn(credentials) }
    await #expect(throws: FeatureUnavailable.self) { try await unconfigured.register(credentials) }
    await #expect(throws: FeatureUnavailable.self) { try await unconfigured.signInWithGoogle() }
}

@Test func endingTheSessionRevokesItAndClearsTokens() async throws {
    let http = FakeHTTPClient(response: .success(Data()))
    let store = InMemoryTokenStore(signedIn)

    await StoredSessionService(api: AuthAPI(client: http, baseURL: baseURL), store: store).endSession()

    #expect(http.requests.first?.url?.path == "/users/logout")
    #expect(try jsonBody(http.requests.first) == ["refresh_token": "refresh-1"])
    #expect(store.load() == nil)
}

@Test func offlineSignOutStillClearsTokens() async {
    let http = FakeHTTPClient(response: .failure(URLError(.notConnectedToInternet)))
    let store = InMemoryTokenStore(signedIn)
    let session = StoredSessionService(api: AuthAPI(client: http, baseURL: baseURL), store: store)

    await session.endSession()

    #expect(store.load() == nil)
    #expect(!session.hasActiveSession())
}

@Test @MainActor func signOutAlsoForgetsTheRouteAndStopsAudio() async {
    let store = InMemoryTokenStore(signedIn)
    let routes = InMemoryRouteStore()
    routes.route = RouteModificationHarness().storeActiveRoute()
    let arbiter = SpyArbiter()

    await SignOutService(
        session: StoredSessionService(api: nil, store: store), routes: routes, arbiter: arbiter
    ).signOut()

    #expect(store.load() == nil)
    #expect(routes.route == nil)
    #expect(arbiter.resets == 1)
}

// MARK: - Peticiones autorizadas

@Test func authorizedRequestsCarryTheAccessToken() async throws {
    let http = FakeHTTPClient(response: .success(Data("ok".utf8)))
    let client = AuthorizedHTTPClient(
        base: http, api: AuthAPI(client: http, baseURL: baseURL), store: InMemoryTokenStore(signedIn)
    )

    _ = try await client.send(URLRequest(url: baseURL.appendingPathComponent("places/routes/active")))

    #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
}

@Test func withoutSessionNothingIsSent() async {
    let http = FakeHTTPClient(response: .success(Data()))
    let client = AuthorizedHTTPClient(
        base: http, api: AuthAPI(client: http, baseURL: baseURL), store: InMemoryTokenStore()
    )

    await #expect(throws: AuthenticationError.notSignedIn) {
        try await client.send(URLRequest(url: baseURL))
    }
    #expect(http.requests.isEmpty)
}

@Test func expiredAccessTokenIsRenewedOnceAndRetried() async throws {
    let http = FakeHTTPClient(response: .success(Data("ok".utf8)))
    http.queued = [.failure(HTTPClientError.statusCode(401)), .success(tokenPair)]
    let store = InMemoryTokenStore(signedIn)
    let client = AuthorizedHTTPClient(base: http, api: AuthAPI(client: http, baseURL: baseURL), store: store)

    let data = try await client.send(URLRequest(url: baseURL.appendingPathComponent("places/routes/active")))

    #expect(String(decoding: data, as: UTF8.self) == "ok")
    #expect(http.requests.map { $0.url?.path } == [
        "/places/routes/active", "/users/refresh", "/places/routes/active",
    ])
    #expect(http.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
    #expect(store.load() == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
}

@Test func rejectedRefreshClearsTheSession() async {
    let http = FakeHTTPClient(response: .failure(HTTPClientError.statusCode(401)))
    let store = InMemoryTokenStore(signedIn)
    let client = AuthorizedHTTPClient(base: http, api: AuthAPI(client: http, baseURL: baseURL), store: store)

    await #expect(throws: AuthenticationError.sessionExpired) {
        try await client.send(URLRequest(url: baseURL))
    }
    #expect(store.load() == nil)
    // Petición original + refresh; no se reintenta en bucle.
    #expect(http.requests.count == 2)
}

@Test func networkErrorWhileRenewingKeepsTheSession() async {
    let http = FakeHTTPClient(response: .failure(URLError(.notConnectedToInternet)))
    http.queued = [.failure(HTTPClientError.statusCode(401))]
    let store = InMemoryTokenStore(signedIn)
    let client = AuthorizedHTTPClient(base: http, api: AuthAPI(client: http, baseURL: baseURL), store: store)

    await #expect(throws: URLError.self) { try await client.send(URLRequest(url: baseURL)) }
    #expect(store.load() == signedIn)
}

@Test func secondRejectionAfterRenewingIsNotRetriedAgain() async {
    let http = FakeHTTPClient(response: .failure(HTTPClientError.statusCode(401)))
    http.queued = [.failure(HTTPClientError.statusCode(401)), .success(tokenPair)]
    let client = AuthorizedHTTPClient(
        base: http, api: AuthAPI(client: http, baseURL: baseURL), store: InMemoryTokenStore(signedIn)
    )

    await #expect(throws: HTTPClientError.self) { try await client.send(URLRequest(url: baseURL)) }
    #expect(http.requests.count == 3)
}
