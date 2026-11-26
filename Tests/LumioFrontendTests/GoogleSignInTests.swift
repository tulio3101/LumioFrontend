import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

/// Iniciar sesión con Google (SCRUM-62): OAuth con PKCE, POST /users/login/google, avisos por
/// el AudioArbiter (cancelación, sin red y demás errores) y asociar Google desde Mi cuenta.

private let baseURL = URL(string: "http://localhost:8000")!
private let tokenPair = Data("""
{"access_token":"access-2","refresh_token":"refresh-2","token_type":"bearer","expires_in":900}
""".utf8)
private let clientID = "1234-abc.apps.googleusercontent.com"

/// JWT sin firma válida con el payload dado (el teléfono no verifica la firma).
private func jwt(_ payload: String) -> String {
    "eyJhbGciOiJSUzI1NiJ9.\(GoogleAuthorizationRequest.base64URL(Data(payload.utf8))).firma"
}

private let anaToken = GoogleIDToken(value: jwt(#"{"sub":"123","email":"Ana.Google@Example.com"}"#))

@MainActor
private final class FakeGoogleProvider: GoogleIDTokenProviding {
    var result: Result<GoogleIDToken, Error> = .success(anaToken)
    private(set) var requests = 0

    func requestIDToken() async throws -> GoogleIDToken {
        requests += 1
        return try result.get()
    }
}

@MainActor
private final class GoogleAccount: CurrentAccountStoring {
    var currentAccountID: String?
    var pendingOwnerAccountID: String?
}

/// Servicio real con dobles: Google, backend, Keychain, árbitro y red.
@MainActor
private struct GoogleHarness {
    let google = FakeGoogleProvider()
    let http: FakeHTTPClient
    let store = InMemoryTokenStore()
    let account = GoogleAccount()
    let history = SpyPendingHistory()
    let arbiter = SpyArbiter()
    let connectivity = FakeConnectivity()
    let service: AnnouncedAuthenticationService

    init(response: Result<Data, Error> = .success(tokenPair)) {
        http = FakeHTTPClient(response: response)
        let remote = RemoteAuthenticationService(
            api: AuthAPI(client: http, baseURL: baseURL), store: store, google: google,
            account: account, pendingHistory: history
        )
        service = AnnouncedAuthenticationService(
            base: remote,
            announcer: GoogleSignInAnnouncer(arbiter: arbiter, connectivity: connectivity)
        )
    }

    var spoken: [AudioMessage] { arbiter.received }

    func failure() async -> GoogleSignInFailure? {
        do {
            try await service.signInWithGoogle()
            return nil
        } catch {
            return error as? GoogleSignInFailure
        }
    }
}

// MARK: - Configuración y OAuth

@Test func googleIsUnavailableWithoutAValidClientID() {
    #expect(AppConfiguration(info: [:]).google == nil)
    #expect(AppConfiguration(info: ["GoogleClientID": "  "]).google == nil)
    #expect(AppConfiguration(info: ["GoogleClientID": "no-es-de-google"]).google == nil)
    #expect(AppConfiguration(info: ["GoogleClientID": " \(clientID) "]).google?.clientID == clientID)
}

@Test func redirectUsesTheReversedClientID() throws {
    let configuration = try #require(GoogleOAuthConfiguration(clientID: clientID))

    #expect(configuration.callbackScheme == "com.googleusercontent.apps.1234-abc")
    #expect(configuration.redirectURI == "com.googleusercontent.apps.1234-abc:/oauth2redirect")
}

@Test func authorizationURLAsksForCodeWithPKCE() throws {
    let configuration = try #require(GoogleOAuthConfiguration(clientID: clientID))
    let request = GoogleAuthorizationRequest(
        configuration: configuration, codeVerifier: "verificador", state: "estado", nonce: "nonce"
    )

    let url = request.authorizationURL
    let items = Dictionary(
        uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }
    )
    #expect(url.host == "accounts.google.com")
    #expect(items["client_id"] == clientID)
    #expect(items["response_type"] == "code")
    #expect(items["redirect_uri"] == configuration.redirectURI)
    #expect(items["scope"]?.contains("openid") == true)
    #expect(items["scope"]?.contains("email") == true)
    #expect(items["code_challenge_method"] == "S256")
    #expect(items["code_challenge"] == GoogleAuthorizationRequest.codeChallenge(for: "verificador"))
    #expect(items["state"] == "estado")
    #expect(items["nonce"] == "nonce")
}

@Test func codeChallengeIsBase64URLOfSHA256() {
    // SHA-256 calculado aparte (.NET) y pasado a base64url sin relleno.
    #expect(
        GoogleAuthorizationRequest.codeChallenge(for: "verificador-de-prueba-lumio")
            == "VH6h5okAvjzmbxuoO0hZbUZZaWJTKqRzYdjyilmmN4I"
    )
    #expect(GoogleAuthorizationRequest.base64URL(Data([0xFB, 0xFF, 0xFE])) == "-__-")
}

@Test func randomVerifierHasTheLengthPKCERequires() {
    let verifier = GoogleAuthorizationRequest.randomToken()

    #expect(verifier.count == 43)
    #expect(!verifier.contains("=") && !verifier.contains("+") && !verifier.contains("/"))
    #expect(GoogleAuthorizationRequest.randomToken() != verifier)
}

@Test func callbackGivesTheCodeOnlyWithTheSameState() throws {
    let configuration = try #require(GoogleOAuthConfiguration(clientID: clientID))
    let request = GoogleAuthorizationRequest(configuration: configuration, state: "estado")
    let scheme = configuration.callbackScheme

    let code = try request.authorizationCode(from: URL(string: "\(scheme):/oauth2redirect?state=estado&code=abc")!)

    #expect(code == "abc")
    #expect(throws: GoogleSignInFailure.server) {
        try request.authorizationCode(from: URL(string: "\(scheme):/oauth2redirect?state=otro&code=abc")!)
    }
    #expect(throws: GoogleSignInFailure.cancelled) {
        try request.authorizationCode(from: URL(string: "\(scheme):/oauth2redirect?error=access_denied")!)
    }
}

@Test func tokenRequestExchangesTheCodeWithTheVerifier() throws {
    let configuration = try #require(GoogleOAuthConfiguration(clientID: clientID))
    let request = GoogleAuthorizationRequest(configuration: configuration, codeVerifier: "verificador")

    let token = request.tokenRequest(code: "4/código")

    #expect(token.url == GoogleOAuthConfiguration.tokenEndpoint)
    #expect(token.httpMethod == "POST")
    let body = String(decoding: try #require(token.httpBody), as: UTF8.self)
    #expect(body.contains("grant_type=authorization_code"))
    #expect(body.contains("code_verifier=verificador"))
    #expect(body.contains("client_id=\(clientID)"))
    #expect(body.contains("code=4%2Fc%C3%B3digo"))
    #expect(!body.contains("client_secret"))
}

@Test func idTokenComesFromTheTokenResponse() throws {
    let data = Data(#"{"access_token":"g","id_token":"\#(anaToken.value)","expires_in":3599}"#.utf8)

    let token = try GoogleAuthorizationRequest.idToken(fromTokenResponse: data)

    #expect(token.value == anaToken.value)
    #expect(token.email == "Ana.Google@Example.com")
    #expect(throws: GoogleSignInFailure.server) {
        try GoogleAuthorizationRequest.idToken(fromTokenResponse: Data("{}".utf8))
    }
}

@Test func emailIsReadFromTheJWTPayload() {
    #expect(GoogleIDToken.email(fromJWT: anaToken.value) == "Ana.Google@Example.com")
    #expect(GoogleIDToken.email(fromJWT: jwt(#"{"sub":"1"}"#)) == nil)
    #expect(GoogleIDToken.email(fromJWT: "no-es-un-jwt") == nil)
}

// MARK: - POST /users/login/google

@Test func googleLoginSendsTheIDToken() async throws {
    let http = FakeHTTPClient(response: .success(tokenPair))

    let tokens = try await AuthAPI(client: http, baseURL: baseURL).loginWithGoogle(idToken: "id-token")

    #expect(tokens == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
    let request = try #require(http.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "http://localhost:8000/users/login/google")
    let body = try #require(request.httpBody)
    #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["id_token": "id-token"])
}

@Test(arguments: [
    (401, GoogleSignInFailure.rejected),
    (409, GoogleSignInFailure.accountConflict),
    (503, GoogleSignInFailure.unavailable),
])
func googleLoginTranslatesBackendErrors(status: Int, expected: GoogleSignInFailure) async {
    let http = FakeHTTPClient(response: .failure(HTTPClientError.statusCode(status)))

    await #expect(throws: expected) {
        try await AuthAPI(client: http, baseURL: baseURL).loginWithGoogle(idToken: "id-token")
    }
}

// MARK: - Servicio con audio

@Test @MainActor func signingInWithGoogleSavesTheSessionSilently() async throws {
    let harness = GoogleHarness()

    try await harness.service.signInWithGoogle()

    #expect(harness.store.load() == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
    #expect(harness.account.currentAccountID == "ana.google@example.com")
    #expect(harness.history.flushes == 1)
    // Al entrar habla la pantalla principal; aquí no se locuta nada.
    #expect(harness.spoken.isEmpty)
}

@Test @MainActor func cancellingIsAnnouncedAndLeavesNoSession() async {
    let harness = GoogleHarness()
    harness.google.result = .failure(GoogleSignInFailure.cancelled)

    #expect(await harness.failure() == .cancelled)

    #expect(harness.store.load() == nil)
    #expect(harness.http.requests.isEmpty)
    let message = harness.spoken.last
    #expect(message?.text == GoogleSignInAnnouncements.message(for: .cancelled))
    #expect(message?.priority == .routeInformation)
    #expect(message?.contextID == GoogleSignInAnnouncements.contextID)
}

@Test @MainActor func withoutNetworkGoogleIsNotOpenedAndItIsAnnounced() async {
    let harness = GoogleHarness()
    harness.connectivity.isConnected = false

    #expect(await harness.failure() == .offline)

    #expect(harness.google.requests == 0)
    #expect(harness.spoken.last?.text == GoogleSignInAnnouncements.message(for: .offline))
}

@Test @MainActor func losingNetworkMidwayIsAnnouncedAsOffline() async {
    let harness = GoogleHarness(response: .failure(URLError(.notConnectedToInternet)))

    #expect(await harness.failure() == .offline)

    #expect(harness.store.load() == nil)
    #expect(harness.spoken.last?.text.hasPrefix("Sin conexión") == true)
}

@Test @MainActor func emailOfAPasswordAccountExplainsHowToLink() async {
    let harness = GoogleHarness(response: .failure(HTTPClientError.statusCode(409)))

    #expect(await harness.failure() == .accountConflict)

    #expect(harness.store.load() == nil)
    #expect(harness.spoken.last?.text.contains("Mi cuenta") == true)
}

@Test @MainActor func failedKeychainIsAnnouncedAsAnError() async {
    let harness = GoogleHarness()
    harness.store.failSave = true

    #expect(await harness.failure() == .server)
    #expect(harness.spoken.count == 1)
}

@Test @MainActor func withoutGoogleConfiguredItIsUnavailable() async {
    let arbiter = SpyArbiter()
    let service = AnnouncedAuthenticationService(
        base: RemoteAuthenticationService(
            api: AuthAPI(client: FakeHTTPClient(response: .success(tokenPair)), baseURL: baseURL),
            store: InMemoryTokenStore()
        ),
        announcer: GoogleSignInAnnouncer(arbiter: arbiter)
    )

    await #expect(throws: GoogleSignInFailure.unavailable) { try await service.signInWithGoogle() }
    #expect(arbiter.received.last?.text == GoogleSignInAnnouncements.message(for: .unavailable))
}

@Test @MainActor func emailSignInIsNotAnnouncedByTheGoogleWrapper() async throws {
    let harness = GoogleHarness()

    try await harness.service.signIn(AccountCredentials(email: "ana@example.com", password: "clave-segura-1"))

    #expect(harness.spoken.isEmpty)
    #expect(harness.google.requests == 0)
}

// MARK: - Pantalla de acceso

#if canImport(SwiftUI)
@Test @MainActor func formShowsTheSpokenMessageWithoutRepeatingItWithVoiceOver() async {
    let harness = GoogleHarness()
    harness.google.result = .failure(GoogleSignInFailure.cancelled)
    var authenticated = false
    let model = AccountFormViewModel(access: .signIn, service: harness.service) { authenticated = true }

    await model.signInWithGoogle()

    #expect(!authenticated)
    #expect(model.operation == nil)
    #expect(model.failure?.title == "Inicio de sesión cancelado")
    #expect(model.failure?.message == GoogleSignInAnnouncements.message(for: .cancelled))
    #expect(model.failure?.isAnnouncedByAudio == true)
    #expect(model.failure?.isServiceUnavailable == false)
}

@Test @MainActor func formEntersTheAppAfterGoogle() async {
    let harness = GoogleHarness()
    var authenticated = false
    let model = AccountFormViewModel(access: .signUp, service: harness.service) { authenticated = true }

    await model.signInWithGoogle()

    #expect(authenticated)
    #expect(model.failure == nil)
}
#endif

// MARK: - Asociar Google desde Mi cuenta

@MainActor
private struct LinkHarness {
    let remote = FakeProfileRemote()
    let google = FakeGoogleProvider()
    let arbiter = SpyArbiter()
    let connectivity = FakeConnectivity()
    let tokens = InMemoryTokenStore(AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
    let service: ProfileService

    init() {
        service = ProfileService(
            remote: remote, tokens: tokens, arbiter: arbiter, google: google, connectivity: connectivity
        )
    }
}

@Test @MainActor func linkingSendsTheGoogleTokenAndAnnouncesIt() async {
    let harness = LinkHarness()

    let outcome = await harness.service.linkGoogle()

    guard case .linked(let profile) = outcome else {
        Issue.record("Se esperaba .linked y llegó \(outcome)")
        return
    }
    #expect(profile.googleLinked)
    #expect(harness.remote.linkedTokens == [anaToken.value])
    #expect(harness.arbiter.received.last?.text == GoogleSignInAnnouncements.linked)
    #expect(harness.arbiter.received.last?.contextID == ProfileService.contextID)
}

@Test @MainActor func cancellingTheLinkChangesNothing() async {
    let harness = LinkHarness()
    harness.google.result = .failure(GoogleSignInFailure.cancelled)

    #expect(await harness.service.linkGoogle() == .failed(.cancelled))

    #expect(harness.remote.linkedTokens.isEmpty)
    #expect(harness.arbiter.received.last?.text == GoogleSignInAnnouncements.message(for: .cancelled))
}

@Test @MainActor func linkingWithoutNetworkDoesNotOpenGoogle() async {
    let harness = LinkHarness()
    harness.connectivity.isConnected = false

    #expect(await harness.service.linkGoogle() == .failed(.offline))
    #expect(harness.google.requests == 0)
}

@Test @MainActor func linkingAGoogleAccountOfAnotherUserIsExplained() async {
    let harness = LinkHarness()
    harness.remote.linkResult = .failure(GoogleSignInFailure.accountInUse)

    #expect(await harness.service.linkGoogle() == .failed(.accountInUse))
    #expect(harness.arbiter.received.last?.text == GoogleSignInAnnouncements.message(for: .accountInUse))
}

@Test @MainActor func expiredSessionWhileLinkingClearsTheTokens() async {
    let harness = LinkHarness()
    harness.remote.linkResult = .failure(AuthenticationError.sessionExpired)

    #expect(await harness.service.linkGoogle() == .failed(.sessionExpired))
    #expect(harness.tokens.load() == nil)
}

@Test(arguments: [
    (403, GoogleSignInFailure.rejected),
    (409, GoogleSignInFailure.accountInUse),
    (503, GoogleSignInFailure.unavailable),
])
func linkEndpointTranslatesBackendErrors(status: Int, expected: GoogleSignInFailure) async {
    let remote = RemoteProfileService(
        client: FakeHTTPClient(response: .failure(HTTPClientError.statusCode(status))), baseURL: baseURL
    )

    await #expect(throws: expected) { _ = try await remote.linkGoogle(idToken: "id-token") }
}

@Test func linkEndpointPostsTheTokenAndReadsGoogleLinked() async throws {
    let http = FakeHTTPClient(response: .success(Data("""
    {"id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","email":"ana@example.com","display_name":null,
    "phone":null,"google_linked":true,"created_at":"2026-11-20T10:00:00Z"}
    """.utf8)))

    let profile = try await RemoteProfileService(client: http, baseURL: baseURL).linkGoogle(idToken: "id-token")

    #expect(profile.googleLinked)
    let request = try #require(http.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "http://localhost:8000/users/me/google")
}

#if canImport(SwiftUI)
@Test @MainActor func profileHidesTheLinkButtonOnceLinked() async {
    let harness = LinkHarness()
    let model = ProfileViewModel(service: harness.service, onSessionExpired: {})
    await model.load()
    #expect(!model.googleLinked)

    await model.linkGoogle()

    #expect(model.googleLinked)
    #expect(model.googleBanner?.status == .success)
    await model.linkGoogle()
    #expect(harness.remote.linkedTokens.count == 1)
}
#endif
