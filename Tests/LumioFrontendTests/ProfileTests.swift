import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

/// Personalizar Cuenta (SCRUM-6): reglas, servicio con dobles y cliente del backend.

private let baseURL = URL(string: "http://localhost:8000")!
private let anaID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
private let ana = UserProfile(id: anaID, email: "ana@example.com", displayName: "Ana", phone: "3001234567")
private let userRead = Data("""
{"id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","email":"ana@example.com","display_name":"Ana",
"phone":"3001234567","created_at":"2026-11-20T10:00:00Z"}
""".utf8)

@MainActor
final class FakeProfileRemote: ProfileRemoting {
    var profile = ana
    var loadResult: Result<Void, Error> = .success(())
    var updateResult: Result<Void, Error> = .success(())
    var passwordResult: Result<Void, Error> = .success(())
    private(set) var updates: [ProfileChanges] = []
    private(set) var passwordChanges: [(current: String, new: String)] = []

    func loadProfile() async throws -> UserProfile {
        try loadResult.get()
        return profile
    }

    func updateProfile(_ changes: ProfileChanges) async throws -> UserProfile {
        updates.append(changes)
        try updateResult.get()
        profile.displayName = changes.displayName
        profile.phone = changes.phone
        return profile
    }

    func changePassword(current: String, new: String) async throws {
        passwordChanges.append((current, new))
        try passwordResult.get()
    }
}

@MainActor
private struct ProfileHarness {
    let remote = FakeProfileRemote()
    let arbiter = SpyArbiter()
    let tokens = InMemoryTokenStore(AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
    let service: ProfileService

    init() {
        service = ProfileService(remote: remote, tokens: tokens, arbiter: arbiter)
    }

    var lastSpoken: String? { arbiter.received.last?.text }

    func loaded() async -> ProfileHarness {
        _ = await service.loadProfile()
        return self
    }
}

// MARK: - Reglas del nombre y del celular

@Test func validProfilesPass() {
    for (name, phone) in [
        ("Ana María", "3001234567"), ("  O'Neill-Pérez Jr. ", "300 123-4567"), ("", ""), ("Ñ" + String(repeating: "á", count: 59), ""),
    ] {
        #expect(ProfilePolicy.validate(displayName: name, phone: phone) == ProfileValidation(), "\(name) \(phone)")
    }
}

@Test func invalidNamesAreRejected() {
    #expect(ProfilePolicy.validate(displayName: "R2-D2", phone: "").displayName == .invalidCharacters)
    #expect(ProfilePolicy.validate(displayName: "...", phone: "").displayName == .invalidCharacters)
    #expect(ProfilePolicy.validate(displayName: "Ana 🙂", phone: "").displayName == .invalidCharacters)
    #expect(ProfilePolicy.validate(displayName: String(repeating: "a", count: 61), phone: "").displayName
        == .tooLong(maximum: 60))
}

@Test func invalidPhonesAreRejected() {
    for phone in ["2001234567", "300123456", "30012345678", "+573001234567", "300abc4567", "３００１２３４５６７"] {
        #expect(ProfilePolicy.validate(displayName: "", phone: phone).phone == .invalid, "\(phone)")
    }
}

@Test func valuesAreNormalizedLikeTheBackend() {
    #expect(ProfilePolicy.changes(displayName: "  Ana   María ", phone: "300 123-4567")
        == ProfileChanges(displayName: "Ana María", phone: "3001234567"))
    #expect(ProfilePolicy.changes(displayName: "   ", phone: " ") == ProfileChanges(displayName: nil, phone: nil))
    // «é» escrita con tilde combinante se envía compuesta.
    #expect(ProfilePolicy.normalizedDisplayName("Jose\u{301}")?.unicodeScalars.count == 4)
}

@Test func firstInvalidFieldFollowsTheScreenOrder() {
    let validation = ProfilePolicy.validate(displayName: "R2", phone: "1")
    #expect(validation.firstInvalidField == .displayName)
    #expect(ProfileAnnouncements.messages(for: validation).count == 2)
}

// MARK: - Reglas de la contraseña

@Test func passwordChangeRules() {
    #expect(PasswordChangePolicy.validate(current: "clave-actual", new: "clave-nueva-1", confirmation: "clave-nueva-1")
        == PasswordChangeValidation())
    #expect(PasswordChangePolicy.validate(current: "", new: "clave-nueva-1", confirmation: "clave-nueva-1").currentMissing)
    #expect(PasswordChangePolicy.validate(current: "a", new: "", confirmation: "").new == .missing)
    #expect(PasswordChangePolicy.validate(current: "a", new: "corta", confirmation: "corta").new == .tooShort(minimum: 8))
    let long = String(repeating: "x", count: 129)
    #expect(PasswordChangePolicy.validate(current: "a", new: long, confirmation: long).new == .tooLong(maximum: 128))
    #expect(PasswordChangePolicy.validate(current: "misma-clave", new: "misma-clave", confirmation: "misma-clave").new
        == .sameAsCurrent)
    #expect(PasswordChangePolicy.validate(current: "a", new: "clave-nueva-1", confirmation: "clave-nueva-2")
        .confirmationMismatch)
}

// MARK: - Consultar

@Test @MainActor func profileIsLoadedWithoutSpeaking() async {
    let harness = ProfileHarness()

    let result = await harness.service.loadProfile()

    #expect(result == .success(ana))
    #expect(harness.arbiter.received.isEmpty)
}

@Test @MainActor func loadFailureIsSpoken() async {
    let harness = ProfileHarness()
    harness.remote.loadResult = .failure(URLError(.notConnectedToInternet))

    let result = await harness.service.loadProfile()

    #expect(result == .failure(.offline))
    #expect(harness.lastSpoken == "Sin conexión. No se pudo consultar tu cuenta. Intenta de nuevo cuando tengas conexión.")
    #expect(harness.arbiter.received.last?.contextID == ProfileService.contextID)
}

// MARK: - Guardar

@Test @MainActor func validChangesAreSavedAndAnnounced() async {
    let harness = await ProfileHarness().loaded()

    let outcome = await harness.service.saveProfile(displayName: " Ana  María ", phone: "310 555 0101")

    let expected = UserProfile(id: anaID, email: "ana@example.com", displayName: "Ana María", phone: "3105550101")
    #expect(outcome == .saved(expected))
    #expect(harness.remote.updates == [ProfileChanges(displayName: "Ana María", phone: "3105550101")])
    #expect(harness.lastSpoken == "Cambios guardados.")
    #expect(harness.service.current == expected)
}

@Test @MainActor func clearingAFieldSendsNull() async {
    let harness = await ProfileHarness().loaded()

    _ = await harness.service.saveProfile(displayName: "Ana", phone: "")

    #expect(harness.remote.updates == [ProfileChanges(displayName: "Ana", phone: nil)])
}

@Test @MainActor func invalidDataIsNotSentAndIsSpoken() async {
    let harness = await ProfileHarness().loaded()

    let outcome = await harness.service.saveProfile(displayName: "R2-D2", phone: "123")

    guard case .invalid(let validation) = outcome else {
        Issue.record("Se esperaba .invalid, llegó \(outcome)")
        return
    }
    #expect(validation.displayName == .invalidCharacters)
    #expect(validation.phone == .invalid)
    #expect(harness.remote.updates.isEmpty)
    #expect(harness.lastSpoken == "Revisa los datos. El nombre solo puede tener letras, espacios, apóstrofos, "
        + "puntos y guiones. El celular debe tener 10 dígitos y empezar por 3.")
}

@Test @MainActor func unchangedProfileIsNotSent() async {
    let harness = await ProfileHarness().loaded()

    let outcome = await harness.service.saveProfile(displayName: " Ana ", phone: "300-123-4567")

    #expect(outcome == .unchanged)
    #expect(harness.remote.updates.isEmpty)
    #expect(harness.lastSpoken == "No hay cambios para guardar.")
}

@Test @MainActor func failedSaveKeepsTheLastSavedProfileAndIsSpoken() async {
    let harness = await ProfileHarness().loaded()
    harness.remote.updateResult = .failure(HTTPClientError.statusCode(503))

    let outcome = await harness.service.saveProfile(displayName: "Luis", phone: "")

    #expect(outcome == .failed(.server))
    #expect(harness.service.current == ana)
    #expect(harness.lastSpoken == "No se pudo guardar los cambios. Intenta de nuevo más tarde. Tus datos siguen como estaban.")
}

@Test @MainActor func offlineSaveIsSpoken() async {
    let harness = await ProfileHarness().loaded()
    harness.remote.updateResult = .failure(URLError(.networkConnectionLost))

    #expect(await harness.service.saveProfile(displayName: "Luis", phone: "") == .failed(.offline))
    #expect(harness.lastSpoken?.hasPrefix("Sin conexión.") == true)
}

@Test @MainActor func expiredSessionClearsTheTokens() async {
    let harness = await ProfileHarness().loaded()
    harness.remote.updateResult = .failure(AuthenticationError.sessionExpired)

    #expect(await harness.service.saveProfile(displayName: "Luis", phone: "") == .failed(.sessionExpired))
    #expect(harness.tokens.load() == nil)
    #expect(harness.lastSpoken == ProfileAnnouncements.sessionExpired)
}

@Test @MainActor func aNewMessageReplacesThePreviousOne() async {
    let harness = await ProfileHarness().loaded()

    _ = await harness.service.saveProfile(displayName: "R2", phone: "")
    _ = await harness.service.saveProfile(displayName: "Luis", phone: "")

    #expect(harness.arbiter.cancelledContexts.last == [ProfileService.contextID])
    #expect(harness.lastSpoken == "Cambios guardados.")
}

// MARK: - Cambiar contraseña

@Test @MainActor func passwordIsChangedAndAnnounced() async {
    let harness = ProfileHarness()

    let outcome = await harness.service.changePassword(
        current: "clave-actual", new: "clave-nueva-1", confirmation: "clave-nueva-1"
    )

    #expect(outcome == .changed)
    #expect(harness.remote.passwordChanges.map(\.current) == ["clave-actual"])
    #expect(harness.remote.passwordChanges.map(\.new) == ["clave-nueva-1"])
    #expect(harness.lastSpoken == "Contraseña cambiada. Se cerró tu sesión en los demás dispositivos.")
    // Este dispositivo sigue con su sesión.
    #expect(harness.tokens.load() != nil)
}

@Test @MainActor func invalidPasswordChangeIsNotSent() async {
    let harness = ProfileHarness()

    let outcome = await harness.service.changePassword(current: "", new: "corta", confirmation: "otra")

    #expect(outcome == .invalid(PasswordChangeValidation(currentMissing: true, new: .tooShort(minimum: 8), confirmationMismatch: true)))
    #expect(harness.remote.passwordChanges.isEmpty)
    #expect(harness.lastSpoken?.hasPrefix("Revisa la contraseña. Escribe tu contraseña actual.") == true)
}

@Test @MainActor func wrongCurrentPasswordIsSpoken() async {
    let harness = ProfileHarness()
    harness.remote.passwordResult = .failure(HTTPClientError.statusCode(403))

    let outcome = await harness.service.changePassword(current: "mala", new: "clave-nueva-1", confirmation: "clave-nueva-1")

    #expect(outcome == .failed(.wrongCurrentPassword))
    #expect(harness.lastSpoken == "La contraseña actual no es correcta. No se cambió la contraseña.")
    // 403 no es una sesión vencida.
    #expect(harness.tokens.load() != nil)
}

@Test func backendErrorsAreClassified() {
    #expect(ProfileService.failure(for: URLError(.notConnectedToInternet)) == .offline)
    #expect(ProfileService.failure(for: URLError(.badServerResponse)) == .server)
    #expect(ProfileService.failure(for: AuthenticationError.sessionExpired) == .sessionExpired)
    #expect(ProfileService.failure(for: AuthenticationError.notSignedIn) == .sessionExpired)
    #expect(ProfileService.failure(for: HTTPClientError.statusCode(401)) == .sessionExpired)
    #expect(ProfileService.failure(for: HTTPClientError.statusCode(403)) == .wrongCurrentPassword)
    #expect(ProfileService.failure(for: HTTPClientError.statusCode(409)) == .passwordNotSet)
    #expect(ProfileService.failure(for: HTTPClientError.statusCode(422)) == .rejected)
    #expect(ProfileService.failure(for: HTTPClientError.statusCode(500)) == .server)
    #expect(ProfileService.failure(for: FeatureUnavailable.authentication) == .server)
}

// MARK: - Backend

private func json(_ request: URLRequest?) throws -> [String: Any] {
    let body = try #require(request?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
}

@Test func loadProfileReadsUsersMe() async throws {
    let http = FakeHTTPClient(response: .success(userRead))

    let profile = try await RemoteProfileService(client: http, baseURL: baseURL).loadProfile()

    #expect(profile == ana)
    #expect(http.requests.first?.httpMethod == "GET")
    #expect(http.requests.first?.url?.absoluteString == "http://localhost:8000/users/me")
}

@Test func updateProfilePatchesBothFieldsWithNullToClear() async throws {
    let http = FakeHTTPClient(response: .success(userRead))

    _ = try await RemoteProfileService(client: http, baseURL: baseURL)
        .updateProfile(ProfileChanges(displayName: "Ana", phone: nil))

    let request = try #require(http.requests.first)
    #expect(request.httpMethod == "PATCH")
    #expect(request.url?.path == "/users/me")
    let body = try json(request)
    #expect(body["display_name"] as? String == "Ana")
    #expect(body.keys.contains("phone"))
    #expect(body["phone"] is NSNull)
}

@Test func changePasswordPutsBothPasswords() async throws {
    let http = FakeHTTPClient(response: .success(Data()))

    try await RemoteProfileService(client: http, baseURL: baseURL).changePassword(current: "actual", new: "clave-nueva-1")

    let request = try #require(http.requests.first)
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.path == "/users/me/password")
    let body = try json(request)
    #expect(body["current_password"] as? String == "actual")
    #expect(body["new_password"] as? String == "clave-nueva-1")
}

@Test func withoutBackendProfileIsUnavailable() async {
    let remote = RemoteProfileService(client: FakeHTTPClient(response: .success(Data())), baseURL: nil)

    await #expect(throws: FeatureUnavailable.self) { try await remote.loadProfile() }
}
