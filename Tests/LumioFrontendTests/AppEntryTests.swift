import Testing
@testable import LumioFrontend

private struct StoredSession: SessionRestoring {
    let isActive: Bool

    func hasActiveSession() -> Bool {
        isActive
    }
}

@Test func withoutSessionOpensWelcome() {
    #expect(AppEntry(session: StoredSession(isActive: false)) == .welcome)
}

@Test func activeSessionSkipsWelcome() {
    #expect(AppEntry(session: StoredSession(isActive: true)) == .home)
}

@Test func sessionStubDoesNotInventSession() {
    #expect(AppEntry(session: UnavailableSessionService()) == .welcome)
}
