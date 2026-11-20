import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

/// Eliminar Cuenta integrado: AudioArbiter real, ruta activa, rutas recientes e historial
/// pendiente en disco, y cliente del backend con sesión (Bearer y refresh).

private let tokenPair = Data("""
{"access_token":"access-2","refresh_token":"refresh-2","token_type":"bearer","expires_in":900}
""".utf8)

@MainActor
private struct DeletionFlow {
    let flow: IntegratedFlow
    let pendingURL = temporaryFileURL()
    let recentURL = temporaryFileURL()
    let history: FinishedRouteSynchronizer
    let finisher: RouteFinishService
    let creator: RouteCreationService
    let deletion: AccountDeletionService

    init(backend: Result<Data, Error>) {
        flow = IntegratedFlow(backend: backend)
        let baseURL = URL(string: "http://localhost:8000")!
        let authorized = AuthorizedHTTPClient(
            base: flow.http, api: AuthAPI(client: flow.http, baseURL: baseURL), store: flow.tokens
        )
        let store = FileActiveRouteStore(fileURL: flow.fileURL)
        let routeSync = RemoteActiveRouteService(client: authorized, baseURL: baseURL)
        history = FinishedRouteSynchronizer(
            store: FileFinishedRoutesStore(fileURL: pendingURL),
            finishSync: RemoteFinishedRouteService(client: authorized, baseURL: baseURL),
            routeSync: routeSync
        )
        finisher = RouteFinishService(store: store, history: history, arbiter: flow.arbiter)
        creator = RouteCreationService(
            location: flow.location, geocoder: flow.geocoder, calculator: flow.calculator,
            store: store, sync: routeSync, arbiter: flow.arbiter, history: history
        )
        deletion = AccountDeletionService(
            remote: RemoteAccountService(client: authorized, baseURL: baseURL),
            tokens: flow.tokens,
            routes: store,
            recentRoutes: FileRecentRoutesStore(fileURL: recentURL),
            pendingHistory: history,
            arbiter: flow.arbiter
        )
    }

    var pending: [FinishedRoute] {
        get throws { try FileFinishedRoutesStore(fileURL: pendingURL).load() }
    }

    var recent: SavedRecentRoutes? {
        get throws { try FileRecentRoutesStore(fileURL: recentURL).load() }
    }

    /// Peticiones al backend desde que terminó `prepareAccountData()`.
    var requests: [URLRequest] { Array(flow.http.requests.dropFirst(requestsBefore)) }
    private var requestsBefore: Int { preparedRequests.count }
    private let preparedRequests = RequestCount()

    /// Una ruta finalizada sin red (pendiente en disco), otra en curso y rutas recientes.
    func prepareAccountData() async throws {
        flow.http.response = .failure(URLError(.notConnectedToInternet))
        _ = try await creator.createRoute(to: .query("Farmacia Central"))
        _ = await finisher.finishActiveRoute(outcome: .completed, trigger: .manual)
        _ = try await creator.createRoute(to: .query("Farmacia Central"))
        try FileRecentRoutesStore(fileURL: recentURL).save(SavedRecentRoutes(destinations: [], savedAt: Date()))
        #expect(try pending.count == 1)
        #expect(try flow.storedRoute != nil)
        #expect(try recent != nil)
        preparedRequests.count = flow.http.requests.count
    }

    func cleanUp() {
        flow.cleanUp()
        for url in [pendingURL, recentURL] {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }
}

@Test @MainActor func deletingTheAccountCallsTheBackendAndForgetsItOnThePhone() async throws {
    let deletion = DeletionFlow(backend: .success(integrationBackendResponse))
    defer { deletion.cleanUp() }
    try await deletion.prepareAccountData()
    deletion.flow.http.response = .success(Data())

    let outcome = await deletion.deletion.deleteAccount()

    #expect(outcome == .deleted)
    // Backend: una sola petición DELETE /users/me con el access token.
    #expect(deletion.requests.map(\.httpMethod) == ["DELETE"])
    let request = try #require(deletion.requests.first)
    #expect(request.url?.path == "/users/me")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    // Teléfono: sin tokens, sin ruta, sin rutas recientes y sin historial pendiente.
    #expect(deletion.flow.tokens.load() == nil)
    #expect(try deletion.flow.storedRoute == nil)
    #expect(try deletion.recent == nil)
    #expect(try deletion.pending.isEmpty)
    // Audio: se cortan las instrucciones de la ruta y solo queda el resultado.
    #expect(deletion.flow.arbiter.currentMessage?.text
        == "Cuenta eliminada. Tu cuenta y sus datos fueron eliminados. Ya no podrás iniciar sesión con ella.")
    #expect(deletion.flow.arbiter.pendingMessages.isEmpty)
}

@Test @MainActor func pendingHistoryIsNotUploadedAfterDeletingTheAccount() async throws {
    let deletion = DeletionFlow(backend: .success(integrationBackendResponse))
    defer { deletion.cleanUp() }
    try await deletion.prepareAccountData()
    deletion.flow.http.response = .success(Data())
    _ = await deletion.deletion.deleteAccount()

    // Al volver la red ya no hay nada que enviar, ni sesión con la que enviarlo.
    #expect(await deletion.history.flush())
    #expect(deletion.requests.map(\.httpMethod) == ["DELETE"])
}

@Test @MainActor func expiredAccessTokenIsRenewedBeforeDeleting() async throws {
    let deletion = DeletionFlow(backend: .success(integrationBackendResponse))
    defer { deletion.cleanUp() }
    try await deletion.prepareAccountData()
    deletion.flow.http.queued = [.failure(HTTPClientError.statusCode(401)), .success(tokenPair)]
    deletion.flow.http.response = .success(Data())

    let outcome = await deletion.deletion.deleteAccount()

    #expect(outcome == .deleted)
    #expect(deletion.requests.map { $0.url?.path } == ["/users/me", "/users/refresh", "/users/me"])
    #expect(deletion.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
    #expect(deletion.flow.tokens.load() == nil)
}

@Test @MainActor func offlineDeletionKeepsEverythingAndSpeaksTheError() async throws {
    let deletion = DeletionFlow(backend: .success(integrationBackendResponse))
    defer { deletion.cleanUp() }
    try await deletion.prepareAccountData()

    let outcome = await deletion.deletion.deleteAccount()

    #expect(outcome == .offline)
    #expect(deletion.flow.tokens.load() != nil)
    #expect(try deletion.flow.storedRoute != nil)
    #expect(try deletion.recent != nil)
    #expect(try deletion.pending.count == 1)
    let spoken = [deletion.flow.arbiter.currentMessage].compactMap { $0 } + deletion.flow.arbiter.pendingMessages
    #expect(spoken.contains { $0.text.hasPrefix("Sin conexión. No se pudo eliminar la cuenta.") })
}

@Test @MainActor func serverErrorKeepsEverything() async throws {
    let deletion = DeletionFlow(backend: .success(integrationBackendResponse))
    defer { deletion.cleanUp() }
    try await deletion.prepareAccountData()
    deletion.flow.http.response = .failure(HTTPClientError.statusCode(500))

    let outcome = await deletion.deletion.deleteAccount()

    #expect(outcome == .failed)
    #expect(deletion.flow.tokens.load() != nil)
    #expect(try deletion.flow.storedRoute != nil)
    #expect(try deletion.pending.count == 1)
}

@Test @MainActor func rejectedSessionSendsTheUserToSignInWithoutDeletingLocalRoutes() async throws {
    let deletion = DeletionFlow(backend: .success(integrationBackendResponse))
    defer { deletion.cleanUp() }
    try await deletion.prepareAccountData()
    // Access token y refresh token rechazados (p. ej. la sesión se cerró en otro lado).
    deletion.flow.http.response = .failure(HTTPClientError.statusCode(401))

    let outcome = await deletion.deletion.deleteAccount()

    #expect(outcome == .sessionExpired)
    #expect(deletion.requests.map { $0.url?.path } == ["/users/me", "/users/refresh"])
    #expect(deletion.flow.tokens.load() == nil)
    #expect(try deletion.flow.storedRoute != nil)
}

private final class RequestCount {
    var count = 0
}
