import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

// Recuperar Contraseña: pedir el código sin revelar si la cuenta existe, restablecer con
// código de 6 dígitos y reglas de contraseña, informar por audio y fallos sin cambiar nada.

private final class FakeRecoveryRemote: PasswordRecoveryRemoting {
    var requestError: Error?
    var resetError: Error?
    private(set) var requested: [String] = []
    private(set) var resets: [(email: String, code: String, newPassword: String)] = []

    func requestCode(email: String) async throws {
        if let requestError { throw requestError }
        requested.append(email)
    }

    func resetPassword(email: String, code: String, newPassword: String) async throws {
        if let resetError { throw resetError }
        resets.append((email: email, code: code, newPassword: newPassword))
    }
}

@MainActor
private struct RecoveryHarness {
    let remote = FakeRecoveryRemote()
    let arbiter = SpyArbiter()
    let service: PasswordRecoveryService

    init() {
        service = PasswordRecoveryService(remote: remote, arbiter: arbiter)
    }

    var spoken: [String] { arbiter.received.map(\.text) }
}

// MARK: - Pedir el código

@Test @MainActor func requestingACodeSaysTheSameWhetherOrNotTheAccountExists() async {
    let harness = RecoveryHarness()

    let outcome = await harness.service.requestCode(email: "  ana@example.com ")

    #expect(outcome == .requested)
    #expect(harness.remote.requested == ["ana@example.com"])
    #expect(harness.spoken == [PasswordRecoveryAnnouncements.requested])
    #expect(harness.arbiter.received.first?.priority == .routeInformation)
    #expect(harness.arbiter.received.first?.contextID == PasswordRecoveryService.contextID)
    #expect(!PasswordRecoveryAnnouncements.requested.contains("no existe"))
}

@Test @MainActor func anInvalidEmailIsNotSent() async {
    let harness = RecoveryHarness()

    let outcome = await harness.service.requestCode(email: "ana@")

    #expect(outcome == .invalid(.invalidFormat))
    #expect(harness.remote.requested.isEmpty)
    #expect(harness.spoken == [PasswordRecoveryAnnouncements.message(for: EmailIssue.invalidFormat)])
}

@Test @MainActor func requestingOfflineSaysItCouldNotBeCompleted() async {
    let harness = RecoveryHarness()
    harness.remote.requestError = URLError(.notConnectedToInternet)

    let outcome = await harness.service.requestCode(email: "ana@example.com")

    #expect(outcome == .failed(.offline))
    #expect(harness.spoken == [PasswordRecoveryAnnouncements.message(for: PasswordRecoveryFailure.offline)])
}

// MARK: - Restablecer

@Test @MainActor func aValidCodeResetsThePassword() async {
    let harness = RecoveryHarness()

    let outcome = await harness.service.resetPassword(
        email: "Ana@example.com ", code: "482 915", newPassword: "nueva-clave-1", confirmation: "nueva-clave-1"
    )

    #expect(outcome == .reset)
    #expect(harness.remote.resets.map { $0.code } == ["482915"])
    #expect(harness.remote.resets.map { $0.email } == ["Ana@example.com"])
    #expect(harness.remote.resets.map { $0.newPassword } == ["nueva-clave-1"])
    #expect(harness.spoken == [PasswordRecoveryAnnouncements.reset])
}

@Test @MainActor func aRejectedCodeIsReportedWithoutDetails() async {
    let harness = RecoveryHarness()
    harness.remote.resetError = HTTPClientError.statusCode(400)

    let outcome = await harness.service.resetPassword(
        email: "ana@example.com", code: "000000", newPassword: "nueva-clave-1", confirmation: "nueva-clave-1"
    )

    #expect(outcome == .failed(.invalidCode))
    #expect(harness.spoken == [PasswordRecoveryAnnouncements.message(for: PasswordRecoveryFailure.invalidCode)])
}

@Test @MainActor func invalidDataIsNotSentAndIsExplained() async {
    let harness = RecoveryHarness()

    let outcome = await harness.service.resetPassword(
        email: "ana@example.com", code: "12a", newPassword: "corta", confirmation: "otra"
    )

    let expected = PasswordResetValidation(
        code: .invalid, newPassword: .tooShort(minimum: 8), confirmationMismatch: true
    )
    #expect(outcome == .invalid(expected))
    #expect(harness.remote.resets.isEmpty)
    #expect(harness.spoken.first?.hasPrefix("Revisa los datos.") == true)
    #expect(harness.spoken.first?.contains("El código tiene 6 dígitos.") == true)
}

@Test func failuresAreClassified() {
    #expect(PasswordRecoveryService.failure(for: FeatureUnavailable.authentication) == .unavailable)
    #expect(PasswordRecoveryService.failure(for: HTTPClientError.statusCode(400)) == .invalidCode)
    #expect(PasswordRecoveryService.failure(for: HTTPClientError.statusCode(422)) == .rejected)
    #expect(PasswordRecoveryService.failure(for: HTTPClientError.statusCode(503)) == .server)
    #expect(PasswordRecoveryService.failure(for: URLError(.timedOut)) == .offline)
}

// MARK: - Reglas

@Test func resetCodeRules() {
    let ok = PasswordResetPolicy.validate(code: "4 8 2 9 1 5", newPassword: "clave-segura", confirmation: "clave-segura")
    #expect(ok.isValid)
    #expect(PasswordResetPolicy.normalizedCode(" 482-915 ") == "482915")
    #expect(PasswordResetPolicy.validate(code: "", newPassword: "clave-segura", confirmation: "clave-segura").code == .missing)
    #expect(PasswordResetPolicy.validate(code: "12345", newPassword: "clave-segura", confirmation: "clave-segura").code == .invalid)
    #expect(PasswordResetPolicy.validate(code: "123456", newPassword: "", confirmation: "").newPassword == .missing)
    let long = String(repeating: "a", count: 129)
    #expect(PasswordResetPolicy.validate(code: "123456", newPassword: long, confirmation: long).newPassword == .tooLong(maximum: 128))
}

// MARK: - Contrato con el backend

@Test func recoveryRequestsMatchTheBackend() async throws {
    let client = FakeHTTPClient(response: .success(Data()))
    let remote = RemotePasswordRecoveryService(client: client, baseURL: URL(string: "http://localhost:8000")!)

    try await remote.requestCode(email: "ana@example.com")
    try await remote.resetPassword(email: "ana@example.com", code: "482915", newPassword: "nueva-clave-1")

    #expect(client.requests.map { $0.url?.path } == ["/users/password-reset", "/users/password-reset/confirm"])
    #expect(client.requests.allSatisfy { $0.httpMethod == "POST" })
    #expect(client.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    let body = try #require(client.requests.last?.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(json == ["email": "ana@example.com", "code": "482915", "new_password": "nueva-clave-1"])
}

@Test func withoutBackendRecoveryIsUnavailable() async {
    await #expect(throws: FeatureUnavailable.self) {
        try await RemotePasswordRecoveryService(client: FakeHTTPClient(response: .success(Data())), baseURL: nil)
            .requestCode(email: "ana@example.com")
    }
}

// MARK: - Pantalla

#if canImport(Combine)
@Test @MainActor func theScreenMovesFromEmailToCodeToDone() async {
    let harness = RecoveryHarness()
    let model = PasswordRecoveryViewModel(service: harness.service, email: "ana@example.com")

    await model.requestCode()
    #expect(model.step == .code)
    #expect(model.banner?.kind == .info)

    model.code = "482915"
    model.newPassword = "nueva-clave-1"
    model.confirmation = "nueva-clave-1"
    await model.resetPassword()

    #expect(model.step == .done)
    #expect(model.banner?.kind == .success)
    #expect(model.validation == PasswordResetValidation())
    #expect(model.newPassword.isEmpty)
}

@Test @MainActor func theScreenShowsFieldErrorsAfterTheFirstAttempt() async {
    let harness = RecoveryHarness()
    let model = PasswordRecoveryViewModel(service: harness.service, email: "ana@example.com")
    await model.requestCode()

    model.newPassword = "corta"
    #expect(model.validation == PasswordResetValidation())
    await model.resetPassword()
    #expect(model.validation.newPassword == .tooShort(minimum: 8))

    model.newPassword = "nueva-clave-1"
    #expect(model.validation.newPassword == nil)
}

@Test @MainActor func theCodeErrorClearsWhileTyping() async {
    let harness = RecoveryHarness()
    let model = PasswordRecoveryViewModel(service: harness.service, email: "ana@example.com")
    await model.requestCode()

    model.code = "12"
    await model.resetPassword()
    #expect(model.validation.code == .invalid)

    model.code = "482915"
    #expect(model.validation.code == nil)
}
#endif
