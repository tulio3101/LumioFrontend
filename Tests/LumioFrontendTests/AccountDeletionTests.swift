import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

/// Eliminar Cuenta (SCRUM-7): servicio con dobles de prueba.

private let baseURL = URL(string: "http://localhost:8000")!
private let signedIn = AuthTokens(accessToken: "access-1", refreshToken: "refresh-1")

@MainActor
final class FakeAccountRemover: AccountRemoving {
    var result: Result<Void, Error> = .success(())
    private(set) var calls = 0
    /// Se ejecuta durante la petición, para comprobar el estado intermedio.
    var onDelete: (() async -> Void)?

    func deleteAccount() async throws {
        calls += 1
        await onDelete?()
        try result.get()
    }
}

@MainActor
private struct DeletionHarness {
    let remote = FakeAccountRemover()
    let tokens = InMemoryTokenStore(signedIn)
    let routes = InMemoryRouteStore()
    let recent = InMemoryRecentRoutesStore()
    let pending = SpyPendingHistory()
    let arbiter = SpyArbiter()
    let service: AccountDeletionService

    init() {
        routes.route = RouteModificationHarness().storeActiveRoute()
        recent.saved = SavedRecentRoutes(destinations: [], savedAt: Date())
        service = AccountDeletionService(
            remote: remote, tokens: tokens, routes: routes, recentRoutes: recent,
            pendingHistory: pending, arbiter: arbiter
        )
    }

    var spoken: [String] { arbiter.received.map(\.text) }

    /// Nada de la cuenta se tocó en el teléfono.
    func expectAccountKept() {
        #expect(tokens.load() == signedIn)
        #expect(routes.route != nil)
        #expect(recent.saved != nil)
        #expect(pending.discards == 0)
        #expect(arbiter.resets == 0)
    }
}

// MARK: - Confirmaciones por audio

@Test @MainActor func consequencesAreSpokenBeforeDeleting() {
    let harness = DeletionHarness()

    harness.service.explainConsequences()

    let message = harness.arbiter.received.last
    #expect(message?.contextID == AccountDeletionService.contextID)
    #expect(message?.priority == .routeInformation)
    for consequence in ["contactos de confianza", "historial de rutas", "preferencias", "No se puede deshacer"] {
        #expect(message?.text.contains(consequence) == true)
    }
    // Explicar no borra nada.
    #expect(harness.remote.calls == 0)
    harness.expectAccountKept()
}

@Test @MainActor func finalConfirmationIsSpokenAndReplacesTheExplanation() {
    let harness = DeletionHarness()
    harness.service.explainConsequences()

    harness.service.askForFinalConfirmation()

    #expect(harness.spoken.last == AccountDeletionAnnouncements.finalConfirmation)
    #expect(harness.spoken.last?.contains("Eliminar definitivamente") == true)
    #expect(harness.arbiter.cancelledContexts.last == [AccountDeletionService.contextID])
    #expect(harness.remote.calls == 0)
}

@Test @MainActor func cancellingStopsTheExplanationAndKeepsTheAccount() {
    let harness = DeletionHarness()
    harness.service.explainConsequences()

    harness.service.cancel()

    #expect(harness.arbiter.cancelledContexts.last == [AccountDeletionService.contextID])
    #expect(harness.remote.calls == 0)
    harness.expectAccountKept()
}

@Test func screenTextMatchesWhatIsSpoken() {
    for consequence in AccountDeletionAnnouncements.consequences {
        #expect(AccountDeletionAnnouncements.explanation.contains(consequence))
    }
    #expect(AccountDeletionAnnouncements.finalConfirmation.hasPrefix(AccountDeletionAnnouncements.finalQuestion))
    #expect(AccountDeletionAnnouncements.finalConfirmation.contains(AccountDeletionAnnouncements.finalMessage))
}

// MARK: - Eliminar

@Test @MainActor func deletedAccountLeavesNothingOnThePhone() async {
    let harness = DeletionHarness()

    let outcome = await harness.service.deleteAccount()

    #expect(outcome == .deleted)
    #expect(harness.remote.calls == 1)
    #expect(harness.tokens.load() == nil)
    #expect(harness.routes.route == nil)
    #expect(harness.recent.saved == nil)
    // Lo pendiente no se envía: la cuenta ya no existe.
    #expect(harness.pending.discards == 1)
    #expect(harness.pending.flushes == 0)
    #expect(harness.arbiter.resets == 1)
    #expect(harness.spoken == [
        AccountDeletionAnnouncements.deleting,
        "Cuenta eliminada. Tu cuenta y sus datos fueron eliminados. Ya no podrás iniciar sesión con ella.",
    ])
    #expect(outcome?.leavesTheApp == true)
}

@Test @MainActor func nothingIsClearedUntilTheBackendConfirms() async {
    let harness = DeletionHarness()
    harness.remote.onDelete = { harness.expectAccountKept() }

    _ = await harness.service.deleteAccount()

    #expect(harness.remote.calls == 1)
}

@Test @MainActor func aSecondTapWhileDeletingIsIgnored() async {
    let harness = DeletionHarness()
    var second: AccountDeletionOutcome?? = .none
    harness.remote.onDelete = { second = await harness.service.deleteAccount() }

    let first = await harness.service.deleteAccount()

    #expect(first == .deleted)
    #expect(second == .some(nil))
    #expect(harness.remote.calls == 1)
}

// MARK: - Manejo de errores

@Test @MainActor func offlineDeletionKeepsTheAccountAndSaysSo() async {
    let harness = DeletionHarness()
    harness.remote.result = .failure(URLError(.notConnectedToInternet))

    let outcome = await harness.service.deleteAccount()

    #expect(outcome == .offline)
    #expect(outcome?.leavesTheApp == false)
    harness.expectAccountKept()
    #expect(harness.spoken.last == "Sin conexión. No se pudo eliminar la cuenta. Tu cuenta sigue activa. "
        + "Intenta de nuevo cuando tengas conexión.")
}

@Test @MainActor func serverFailureKeepsTheAccountAndSaysSo() async {
    let harness = DeletionHarness()
    harness.remote.result = .failure(HTTPClientError.statusCode(503))

    let outcome = await harness.service.deleteAccount()

    #expect(outcome == .failed)
    harness.expectAccountKept()
    #expect(harness.spoken.last?.hasPrefix("No se pudo eliminar la cuenta.") == true)
    #expect(harness.spoken.last?.contains("Tu cuenta sigue activa") == true)
}

@Test @MainActor func expiredSessionAsksToSignInAgain() async {
    let harness = DeletionHarness()
    harness.remote.result = .failure(AuthenticationError.sessionExpired)

    let outcome = await harness.service.deleteAccount()

    #expect(outcome == .sessionExpired)
    #expect(outcome?.leavesTheApp == true)
    #expect(harness.tokens.load() == nil)
    // La cuenta no se borró: lo demás se queda como al expirar la sesión en otra pantalla.
    #expect(harness.routes.route != nil)
    #expect(harness.pending.discards == 0)
    #expect(harness.spoken.last?.contains("Inicia sesión de nuevo") == true)
}

@Test func errorsAreClassifiedForTheUser() {
    #expect(AccountDeletionService.outcome(for: URLError(.notConnectedToInternet)) == .offline)
    #expect(AccountDeletionService.outcome(for: URLError(.timedOut)) == .offline)
    #expect(AccountDeletionService.outcome(for: URLError(.badServerResponse)) == .failed)
    #expect(AccountDeletionService.outcome(for: AuthenticationError.sessionExpired) == .sessionExpired)
    #expect(AccountDeletionService.outcome(for: AuthenticationError.notSignedIn) == .sessionExpired)
    #expect(AccountDeletionService.outcome(for: HTTPClientError.statusCode(401)) == .sessionExpired)
    #expect(AccountDeletionService.outcome(for: HTTPClientError.statusCode(500)) == .failed)
    #expect(AccountDeletionService.outcome(for: FeatureUnavailable.authentication) == .failed)
}

@Test @MainActor func everyFailureIsSpoken() async {
    let failures: [Error] = [
        URLError(.notConnectedToInternet), HTTPClientError.statusCode(500), AuthenticationError.sessionExpired,
    ]
    for failure in failures {
        let harness = DeletionHarness()
        harness.remote.result = .failure(failure)

        let outcome = await harness.service.deleteAccount()

        let expected = AccountDeletionAnnouncements.spoken(for: outcome ?? .deleted)
        #expect(harness.spoken.last == expected)
    }
}

// MARK: - Backend

@Test func deleteAccountSendsDeleteToUsersMe() async throws {
    let http = FakeHTTPClient(response: .success(Data()))

    try await RemoteAccountService(client: http, baseURL: baseURL).deleteAccount()

    let request = try #require(http.requests.first)
    #expect(request.httpMethod == "DELETE")
    #expect(request.url?.absoluteString == "http://localhost:8000/users/me")
}

@Test func withoutBackendAccountDeletionIsUnavailable() async {
    await #expect(throws: FeatureUnavailable.self) {
        try await RemoteAccountService(client: FakeHTTPClient(response: .success(Data())), baseURL: nil)
            .deleteAccount()
    }
}

@Test func backendErrorsArePropagated() async {
    let http = FakeHTTPClient(response: .failure(HTTPClientError.statusCode(503)))

    await #expect(throws: HTTPClientError.self) {
        try await RemoteAccountService(client: http, baseURL: baseURL).deleteAccount()
    }
}
