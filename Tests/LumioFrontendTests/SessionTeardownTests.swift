import Testing
import Foundation
@testable import LumioFrontend

// SCRUM-360: al cerrar sesión (o al expirar/401) se desmonta TODO lo de la ruta activa por un
// único punto (SessionTeardown): detección de obstáculos, llegada, desvío/recálculo, GPS (al
// parar ambos monitores), ruta local y cola de audio. Pruebas portables (solo protocolos).

// MARK: - Dobles

@MainActor
private final class SpySafety: SafetyMonitoring {
    var onEvent: ((SafetyEvent) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    func start() async throws { starts += 1 }
    func stop() { stops += 1 }
}

@MainActor
private final class SpyArrival: ArrivalMonitoring {
    var onArrival: (@MainActor (RouteFinishResult) -> Void)?
    private(set) var stops = 0
    func startMonitoring() {}
    func stopMonitoring() { stops += 1 }
}

@MainActor
private final class SpyDeviation: RouteDeviationMonitoring {
    var onStatusChange: (@MainActor (RerouteStatus?) -> Void)?
    private(set) var stops = 0
    func startMonitoring() {}
    func stopMonitoring() { stops += 1 }
    func rerouteNow() async -> RerouteOutcome? { nil }
}

private final class FakeRouteStore: ActiveRouteStoring, @unchecked Sendable {
    private(set) var clears = 0
    func load() throws -> ActiveRoute? { nil }
    func save(_ route: ActiveRoute) throws {}
    func clear() throws { clears += 1 }
}

@MainActor
private final class FakeRecentStore: RecentRoutesStoring {
    private(set) var clears = 0
    func load() throws -> SavedRecentRoutes? { nil }
    func save(_ routes: SavedRecentRoutes) throws {}
    func clear() throws { clears += 1 }
}

private final class FakePendingHistory: PendingHistorySyncing, @unchecked Sendable {
    private(set) var events: [String] = []
    func enqueue(_ finished: FinishedRoute) throws {}
    func flush() async -> Bool { events.append("flush"); return true }
    func discardPending() { events.append("discard") }
    func park() { events.append("park") }
}

@MainActor
private final class InMemoryAccount: CurrentAccountStoring {
    var currentAccountID: String?
    var pendingOwnerAccountID: String?
}

@MainActor
private final class SpySessionEnding: SessionEnding {
    private(set) var ends = 0
    func endSession() async { ends += 1 }
}

@MainActor
private final class SpyTeardown: SessionTearingDown {
    private(set) var runs = 0
    func tearDown() async { runs += 1 }
}

/// Reproductor mínimo para probar que `resetSession` vacía la cola real del AudioArbiter.
@MainActor
private final class TeardownPlayer: AudioPlaying {
    var onFinished: ((PlaybackToken) -> Void)?
    private(set) var current: PlaybackToken?
    func play(_ message: AudioMessage, token: PlaybackToken) throws { current = token }
    func stop() { current = nil }
}

@MainActor
private func makeTeardown(
    safety: SpySafety,
    arrival: SpyArrival,
    deviation: SpyDeviation,
    arbiter: (any AudioArbitrating)?,
    routes: FakeRouteStore,
    recent: FakeRecentStore? = nil,
    history: FakePendingHistory? = nil
) -> SessionTeardown {
    SessionTeardown(
        safetyMonitor: safety, arrivalMonitor: arrival, deviationMonitor: deviation,
        arbiter: arbiter, routes: routes, recentRoutes: recent, pendingHistory: history
    )
}

// MARK: - Teardown

@Test @MainActor func teardownStopsDetectionArrivalAndDeviation() async {
    let safety = SpySafety(), arrival = SpyArrival(), deviation = SpyDeviation()
    let teardown = makeTeardown(
        safety: safety, arrival: arrival, deviation: deviation,
        arbiter: SpyArbiter(), routes: FakeRouteStore()
    )
    await teardown.tearDown()
    #expect(safety.stops == 1)      // detección (cámara/ARSession) detenida
    #expect(arrival.stops == 1)     // monitor de llegada detenido
    #expect(deviation.stops == 1)   // monitor de desvío/recálculo detenido (apaga el GPS compartido)
}

@Test @MainActor func teardownClearsLocalActiveRouteAndRecents() async {
    let routes = FakeRouteStore(), recent = FakeRecentStore()
    let teardown = makeTeardown(
        safety: SpySafety(), arrival: SpyArrival(), deviation: SpyDeviation(),
        arbiter: SpyArbiter(), routes: routes, recent: recent
    )
    await teardown.tearDown()
    #expect(routes.clears == 1)     // ruta local limpia (otra cuenta no la restaura)
    #expect(recent.clears == 1)
}

@Test @MainActor func teardownFlushesThenParksPendingHistoryBeforeClearing() async {
    let history = FakePendingHistory()
    let teardown = makeTeardown(
        safety: SpySafety(), arrival: SpyArrival(), deviation: SpyDeviation(),
        arbiter: SpyArbiter(), routes: FakeRouteStore(), history: history
    )
    await teardown.tearDown()
    // SCRUM-360: envía lo pendiente y lo APARCA (no lo descarta).
    #expect(history.events == ["flush", "park"])
}

// SCRUM-360 (ajuste 2): el aviso "Sesión cerrada" se emite después del reset y sobrevive;
// los mensajes de ruta y seguridad sí se vacían.
@Test @MainActor func sessionClosedAnnouncementSurvivesTheReset() async {
    let arbiter = AudioArbiterService(player: TeardownPlayer())
    arbiter.receive(AudioMessage(text: "gira a la derecha", priority: .routeInformation, contextID: "route-1"))
    arbiter.receive(AudioMessage(text: "silla a 1 metro", priority: .immediateRisk, contextID: "safety"))
    let teardown = makeTeardown(
        safety: SpySafety(), arrival: SpyArrival(), deviation: SpyDeviation(),
        arbiter: arbiter, routes: FakeRouteStore()
    )
    await teardown.tearDown()
    // Lo único que queda es "Sesión cerrada"; nada de ruta ni seguridad.
    #expect(arbiter.currentMessage?.deduplicationKey == "session-closed")
    #expect(arbiter.pendingMessages.isEmpty)
}

// MARK: - SignOut usa el teardown central

@Test @MainActor func signOutRunsTeardownThenEndsSession() async {
    let teardown = SpyTeardown()
    let session = SpySessionEnding()
    let service = SignOutService(session: session, teardown: teardown)
    await service.signOut()
    #expect(teardown.runs == 1)   // desmonta todo por el punto central
    #expect(session.ends == 1)    // y revoca la sesión
}

// MARK: - Expiración / 401 reutiliza el MISMO teardown

@Test @MainActor func sessionExpiryWithoutActiveRouteTearsDownImmediately() async {
    let teardown = SpyTeardown()
    let coordinator = SessionExpiryCoordinator(
        teardown: teardown, routes: InMemoryRouteStore(), arbiter: SpyArbiter(),
        notifications: NotificationCenter()
    )
    await coordinator.handleExpiry()   // sin ruta activa → desmonta en el acto
    #expect(teardown.runs == 1)
    #expect(coordinator.didExpire)
    await coordinator.handleExpiry()   // idempotente
    #expect(teardown.runs == 1)
}

// SCRUM-360 (ajuste 1): 401 con ruta activa NO apaga la detección; avisa una vez; el teardown
// se difiere hasta finalizar/llegar.
@Test @MainActor func expiryWithActiveRouteDefersTeardownAndAnnouncesOnce() async {
    let teardown = SpyTeardown()
    let routes = InMemoryRouteStore()
    routes.route = activePharmacyRoute()   // hay ruta activa
    let arbiter = SpyArbiter()
    let coordinator = SessionExpiryCoordinator(
        teardown: teardown, routes: routes, arbiter: arbiter, notifications: NotificationCenter()
    )

    await coordinator.handleExpiry()
    #expect(teardown.runs == 0)            // NO se desmonta: la detección/navegación siguen
    #expect(!coordinator.didExpire)
    #expect(coordinator.awaitingRouteEnd)
    let expiredAvisos = arbiter.received.filter { $0.deduplicationKey == "session-expired" }.count
    #expect(expiredAvisos == 1)            // avisado una sola vez

    await coordinator.handleExpiry()       // repetir no vuelve a avisar ni desmonta
    #expect(teardown.runs == 0)
    #expect(arbiter.received.filter { $0.deduplicationKey == "session-expired" }.count == 1)

    // Al terminar/llegar: ahora sí se desmonta y se pide login.
    await coordinator.handleRouteEnded()
    #expect(teardown.runs == 1)
    #expect(coordinator.didExpire)
}

// SCRUM-360 (ajuste 3): lo pendiente no se descarta; se aparca por cuenta y solo lo reenvía el
// mismo usuario; otro usuario no lo sube con su cuenta.
@Test @MainActor func pendingHistoryIsParkedPerAccountAndResentOnlyToTheSameUser() async throws {
    let store = InMemoryFinishedRoutesStore()
    let finishSync = FakeFinishedRouteSync()
    let account = InMemoryAccount()
    account.currentAccountID = "ana@lumio.app"
    let history = FinishedRouteSynchronizer(
        store: store, finishSync: finishSync, routeSync: FakeRouteSync(), account: account
    )
    // Un viaje finalizado sin remoteID (se envía con record()).
    try history.enqueue(FinishedRoute(route: activePharmacyRoute(remoteID: nil), outcome: .completed, finishedAt: finishNow))

    // Cerrar sesión de Ana: se aparca (NO se descarta).
    history.park()
    #expect(store.routes.count == 1)                       // sigue guardado
    #expect(account.pendingOwnerAccountID == "ana@lumio.app")
    #expect(account.currentAccountID == nil)

    // Entra otro usuario: su flush NO sube las rutas de Ana.
    account.currentAccountID = "beto@lumio.app"
    _ = await history.flush()
    #expect(finishSync.calls.isEmpty)                      // no se envió nada
    #expect(store.routes.count == 1)                       // siguen aparcadas

    // Vuelve Ana: ahora sí se reenvían.
    account.currentAccountID = "ana@lumio.app"
    _ = await history.flush()
    #expect(finishSync.calls == ["record"])                // enviado
    #expect(store.routes.isEmpty)                          // entregado
    #expect(account.pendingOwnerAccountID == nil)          // ya no está aparcado
}
