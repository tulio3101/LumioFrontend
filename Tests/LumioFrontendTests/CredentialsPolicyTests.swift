import Testing
@testable import LumioFrontend

@Test func emailIsRequiredAndNeedsUserAndDomain() {
    let issue = { (email: String) in
        CredentialsPolicy.validate(email: email, password: "contraseña", for: .signIn).email
    }
    #expect(issue("") == .missing)
    #expect(issue("   ") == .missing)
    #expect(issue("ana") == .invalidFormat)
    #expect(issue("@correo.com") == .invalidFormat)
    #expect(issue("ana@correo") == .invalidFormat)
    #expect(issue("ana@correo.") == .invalidFormat)
    #expect(issue("ana@@correo.com") == .invalidFormat)
    #expect(issue("ana maria@correo.com") == .invalidFormat)
    #expect(issue(" ana@correo.com ") == nil)
    #expect(CredentialsPolicy.normalizedEmail(" ana@correo.com\n") == "ana@correo.com")
}

@Test func signUpPasswordFollowsBackendLengthLimits() {
    let issue = { (password: String) in
        CredentialsPolicy.validate(email: "ana@correo.com", password: password, for: .signUp).password
    }
    #expect(issue("") == .missing)
    #expect(issue("1234567") == .tooShort(minimum: 8))
    #expect(issue("12345678") == nil)
    #expect(issue(String(repeating: "a", count: 128)) == nil)
    #expect(issue(String(repeating: "a", count: 129)) == .tooLong(maximum: 128))
}

@Test func signInDoesNotRequireMinimumLength() {
    let validation = CredentialsPolicy.validate(email: "ana@correo.com", password: "123", for: .signIn)
    #expect(validation.firstInvalidField == nil)
}

@Test func passwordLengthCountsCodePointsLikeTheBackend() {
    // "👍🏽" es un grafema pero dos puntos de código; Python cuenta 8 en total.
    let validation = CredentialsPolicy.validate(email: "ana@correo.com", password: "123456👍🏽", for: .signUp)
    #expect(validation.password == nil)
}

@Test func firstInvalidFieldFollowsVisualOrder() {
    #expect(CredentialsPolicy.validate(email: "", password: "", for: .signUp).firstInvalidField == .email)
    #expect(CredentialsPolicy.validate(email: "ana@correo.com", password: "", for: .signUp).firstInvalidField == .password)
}

@Test func authenticationStubDoesNotInventAccounts() async {
    let service = UnavailableAuthenticationService()
    let credentials = AccountCredentials(email: "ana@correo.com", password: "12345678")
    await #expect(throws: FeatureUnavailable.self) { try await service.register(credentials) }
    await #expect(throws: FeatureUnavailable.self) { try await service.signIn(credentials) }
    await #expect(throws: FeatureUnavailable.self) { try await service.signInWithGoogle() }
}
