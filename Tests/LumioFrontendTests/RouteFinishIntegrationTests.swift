import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

/// Finalizar Ruta integrado: AudioArbiter real, copia local y cola en disco, y cliente del
/// backend con sesión (ver IntegratedFlow en RouteCreationIntegrationTests).

@MainActor
private struct FinishFlow {
    let flow: IntegratedFlow
    let pendingURL = temporaryFileURL()
    let history: FinishedRouteSynchronizer
    let finisher: RouteFinishService
    let creator: RouteCreationService
    let haptics = SpyHaptics()

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
        finisher = RouteFinishService(store: store, history: history, arbiter: flow.arbiter, haptics: haptics)
        // Crear Ruta con la cola: una ruta nueva espera a que el historial pendiente llegue.
        creator = RouteCreationService(
            location: flow.location, geocoder: flow.geocoder, calculator: flow.calculator,
            store: store, sync: routeSync, arbiter: flow.arbiter, history: history
        )
    }

    var pending: [FinishedRoute] {
        get throws { try FileFinishedRoutesStore(fileURL: pendingURL).load() }
    }

    func cleanUp() {
        flow.cleanUp()
        try? FileManager.default.removeItem(at: pendingURL.deletingLastPathComponent())
    }
}

private func body(_ request: URLRequest?) -> [String: Any] {
    request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
}

@Test @MainActor func manualFinishCutsTheInstructionAndSavesTheRouteInTheHistory() async throws {
    let finish = FinishFlow(backend: .success(integrationBackendResponse))
    defer { finish.cleanUp() }
    _ = try await finish.creator.createRoute(to: .query("Farmacia Central"))
    // «Ruta lista» suena y la primera instrucción espera turno.
    #expect(finish.flow.arbiter.pendingMessages.count == 1)

    let result = try #require(await finish.finisher.finishActiveRoute(outcome: .completed, trigger: .manual))

    // Instrucciones detenidas: se corta lo que sonaba y no queda nada de la ruta.
    #expect(finish.flow.player.stops == 1)
    #expect(finish.flow.arbiter.pendingMessages.isEmpty)
    #expect(finish.flow.arbiter.currentMessage?.text == "Navegación finalizada. Llegaste a Farmacia Central.")
    #expect(finish.haptics.cues == [.routeFinished])
    // Ya no es la ruta activa en el teléfono.
    #expect(try finish.flow.storedRoute == nil)

    #expect(await finish.history.flush())
    let request = try #require(finish.flow.http.requests.last)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/places/routes/\(integrationBackendID.uuidString.lowercased())/finish")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    #expect(body(request)["status"] as? String == "completed")
    #expect(result.finished.route.remoteID == integrationBackendID)
    #expect(try finish.pending.isEmpty)
}

@Test @MainActor func offlineFinishIsSavedWhenTheConnectionReturns() async throws {
    let finish = FinishFlow(backend: .failure(URLError(.notConnectedToInternet)))
    defer { finish.cleanUp() }
    let route = try await finish.creator.createRoute(to: .query("Farmacia Central"))
    #expect(route.remoteID == nil)

    _ = await finish.finisher.finishActiveRoute(outcome: .cancelled, trigger: .manual)
    #expect(await finish.history.flush() == false)
    // Se conserva en el teléfono hasta que haya red.
    #expect(try finish.pending.map(\.route.id) == [route.id])
    #expect(try finish.flow.storedRoute == nil)

    finish.flow.http.response = .success(Data("{}".utf8))
    #expect(await finish.history.flush())

    let request = try #require(finish.flow.http.requests.last)
    #expect(request.url?.path == "/places/routes/history")
    #expect(body(request)["id"] as? String == route.id.uuidString.lowercased())
    #expect(body(request)["status"] as? String == "cancelled")
    #expect(try finish.pending.isEmpty)
}

@Test @MainActor func arrivalFinishesTheRouteOnItsOwn() async throws {
    let finish = FinishFlow(backend: .success(integrationBackendResponse))
    defer { finish.cleanUp() }
    _ = try await finish.creator.createRoute(to: .query("Farmacia Central"))
    let tracker = FakeLocationTracker()
    let monitor = ArrivalMonitor(
        tracker: tracker, store: FileActiveRouteStore(fileURL: finish.flow.fileURL), finisher: finish.finisher
    )
    var arrived: RouteFinishResult?
    monitor.onArrival = { arrived = $0 }
    monitor.startMonitoring()

    await monitor.handle(fix(near: pharmacy))
    await monitor.handle(fix(near: pharmacy, meters: 10))

    #expect(arrived?.trigger == .arrival)
    #expect(arrived?.finished.outcome == .completed)
    #expect(finish.flow.arbiter.currentMessage?.text == "Llegaste a Farmacia Central. La navegación terminó.")
    #expect(try finish.flow.storedRoute == nil)
    #expect(tracker.stops == 1)
}

@Test @MainActor func routeFinishedOfflineAppearsInRecentRoutesOnceOnline() async throws {
    let finish = FinishFlow(backend: .failure(URLError(.notConnectedToInternet)))
    defer { finish.cleanUp() }
    let route = try await finish.creator.createRoute(to: .query("Farmacia Central"))
    _ = await finish.finisher.finishActiveRoute(outcome: .completed, trigger: .manual)
    await finish.history.flush()

    let recordedRoute = Data("{}".utf8)
    let history = Data("""
    {"items":[{"id":"\(route.id.uuidString.lowercased())",
     "origin":{"name":"Ubicación actual","latitude":4.6097,"longitude":-74.0817},
     "destination":{"name":"Farmacia Central","latitude":4.611,"longitude":-74.079},
     "status":"completed","started_at":"2026-11-08T09:00:00Z","finished_at":"2026-11-08T09:20:00Z"}],
     "total":1,"limit":50,"offset":0}
    """.utf8)
    finish.flow.http.queued = [.success(recordedRoute), .success(history)]
    let recentsURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: recentsURL.deletingLastPathComponent()) }
    let baseURL = URL(string: "http://localhost:8000")!
    let recents = RecentRoutesService(
        history: RemoteRouteHistoryService(
            client: AuthorizedHTTPClient(
                base: finish.flow.http, api: AuthAPI(client: finish.flow.http, baseURL: baseURL), store: finish.flow.tokens
            ),
            baseURL: baseURL
        ),
        store: FileRecentRoutesStore(fileURL: recentsURL),
        arbiter: finish.flow.arbiter,
        pendingHistory: finish.history
    )

    let routes = try await recents.recentRoutes(announce: false)

    let paths = finish.flow.http.requests.suffix(2).map { $0.url?.path }
    #expect(paths == ["/places/routes/history", "/places/routes/history"])
    #expect(finish.flow.http.requests.suffix(2).map(\.httpMethod) == ["POST", "GET"])
    #expect(routes.destinations.map(\.place.name) == ["Farmacia Central"])
    #expect(routes.destinations.first?.lastOutcome == .completed)
}

@Test @MainActor func newRouteIsUploadedOnlyAfterThePendingFinish() async throws {
    let finish = FinishFlow(backend: .success(integrationBackendResponse))
    defer { finish.cleanUp() }
    _ = try await finish.creator.createRoute(to: .query("Farmacia Central"))
    finish.flow.http.response = .failure(URLError(.notConnectedToInternet))
    _ = await finish.finisher.finishActiveRoute(outcome: .completed, trigger: .manual)
    await finish.history.flush()
    #expect(try finish.pending.count == 1)

    finish.flow.http.response = .success(integrationBackendResponse)
    let before = finish.flow.http.requests.count
    _ = try await finish.creator.createRoute(to: .query("Farmacia Central"))

    // Primero se cierra la anterior en el backend; si no, al subir la nueva quedaría
    // cancelada en vez de completada.
    let sent = finish.flow.http.requests.dropFirst(before).map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
    #expect(sent == [
        "POST /places/routes/\(integrationBackendID.uuidString.lowercased())/finish",
        "PUT /places/routes/active",
    ])
    #expect(try finish.pending.isEmpty)
}
