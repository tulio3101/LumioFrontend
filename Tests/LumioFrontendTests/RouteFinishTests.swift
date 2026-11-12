import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

/// Finalizar Ruta (SCRUM-10): audio, servicio, cola del historial, detección de llegada y
/// contrato del backend.

// MARK: - Dobles (también los usa RouteFinishIntegrationTests)

let finishNow = Date(timeIntervalSince1970: 1_794_133_200) // 2026-11-08 10:20 UTC

func activePharmacyRoute(remoteID: UUID? = UUID(), revision: Int = 0, pendingChange: Bool = false) -> ActiveRoute {
    ActiveRoute(
        id: UUID(),
        remoteID: remoteID,
        origin: RoutePlace(name: "Ubicación actual", coordinate: currentPosition),
        destination: pharmacy,
        steps: NavigationInstructionBuilder().steps(from: sampleCalculatedRoute().steps),
        distanceMeters: 320,
        expectedTravelTimeSeconds: 260,
        createdAt: finishNow.addingTimeInterval(-1_200),
        revision: revision,
        hasPendingDestinationChange: pendingChange
    )
}

@MainActor
final class InMemoryFinishedRoutesStore: FinishedRoutesStoring {
    var routes: [FinishedRoute] = []

    func load() throws -> [FinishedRoute] { routes }
    func save(_ routes: [FinishedRoute]) throws { self.routes = routes }
}

@MainActor
final class FakeFinishedRouteSync: FinishedRouteSyncing {
    /// Resultados en orden; al agotarse, éxito.
    var finishResults: [Result<Void, Error>] = []
    var recordResults: [Result<Void, Error>] = []
    private(set) var finishes: [(remoteID: UUID, outcome: RouteHistoryEntry.Outcome, finishedAt: Date)] = []
    private(set) var records: [FinishedRoute] = []
    private(set) var calls: [String] = []

    func finish(remoteID: UUID, outcome: RouteHistoryEntry.Outcome, finishedAt: Date) async throws {
        calls.append("finish")
        finishes.append((remoteID, outcome, finishedAt))
        if !finishResults.isEmpty { try finishResults.removeFirst().get() }
    }

    func record(_ finished: FinishedRoute) async throws {
        calls.append("record")
        records.append(finished)
        if !recordResults.isEmpty { try recordResults.removeFirst().get() }
    }
}

@MainActor
final class SpyPendingHistory: PendingHistorySyncing {
    private(set) var enqueued: [FinishedRoute] = []
    private(set) var flushes = 0
    private(set) var discards = 0
    var onEnqueue: (() -> Void)?
    var onFlush: (() -> Void)?

    func enqueue(_ finished: FinishedRoute) throws {
        onEnqueue?()
        enqueued.append(finished)
    }

    func flush() async -> Bool {
        onFlush?()
        flushes += 1
        return true
    }

    func discardPending() { discards += 1 }
}

@MainActor
final class FakeLocationTracker: LocationTracking {
    var onFix: ((LocationFix) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0

    func start() { starts += 1 }
    func stop() { stops += 1 }
}

@MainActor
final class FakeRouteFinisher: RouteFinishing {
    private(set) var calls: [(outcome: RouteHistoryEntry.Outcome, trigger: RouteFinishTrigger)] = []
    var store: InMemoryRouteStore?

    func finishActiveRoute(outcome: RouteHistoryEntry.Outcome, trigger: RouteFinishTrigger) async -> RouteFinishResult? {
        calls.append((outcome, trigger))
        guard let route = store?.route else { return nil }
        store?.route = nil
        return RouteFinishResult(finished: FinishedRoute(route: route, outcome: outcome, finishedAt: finishNow), trigger: trigger)
    }
}

/// Lectura con precisión `accuracy` a `meters` al norte del destino.
func fix(near place: RoutePlace, meters: Double = 5, accuracy: Double = 8) -> LocationFix {
    LocationFix(
        coordinate: GeoCoordinate(
            latitude: place.coordinate.latitude + meters / 111_195, longitude: place.coordinate.longitude
        ),
        horizontalAccuracy: accuracy
    )
}

// MARK: - Árbitro: cortar las instrucciones de una ruta (SCRUM-128)

@Test @MainActor func cancellingAContextStopsItsCurrentAndPendingMessages() {
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player)
    arbiter.receive(AudioMessage(text: "Ruta lista", priority: .routeInformation, contextID: "route-a"))
    arbiter.receive(AudioMessage(text: "Gira a la derecha", priority: .routeInformation, contextID: "route-a"))
    arbiter.receive(AudioMessage(text: "Otro aviso", priority: .routeInformation, contextID: "otro"))

    arbiter.cancel(contextIDs: ["route-a"])

    #expect(player.stops == 1)
    #expect(arbiter.currentMessage?.text == "Otro aviso")
    #expect(arbiter.pendingMessages.isEmpty)
}

@Test @MainActor func cancellingAContextKeepsWhatIsPlayingFromAnother() {
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player)
    arbiter.receive(AudioMessage(text: "Otro aviso", priority: .routeInformation, contextID: "otro"))
    arbiter.receive(AudioMessage(text: "Gira a la derecha", priority: .routeInformation, contextID: "route-a"))

    arbiter.cancel(contextIDs: ["route-a"])

    #expect(player.stops == 0)
    #expect(arbiter.currentMessage?.text == "Otro aviso")
    #expect(arbiter.pendingMessages.isEmpty)
}

// MARK: - Finalizar (SCRUM-126 / 128 / 129 / 131)

@MainActor
private struct FinishHarness {
    let store = InMemoryRouteStore()
    let history = SpyPendingHistory()
    let arbiter = SpyArbiter()
    let haptics = SpyHaptics()

    var service: RouteFinishService {
        RouteFinishService(store: store, history: history, arbiter: arbiter, haptics: haptics, now: { finishNow })
    }
}

@Test @MainActor func manualFinishStopsInstructionsDropsTheCopyAndAnnouncesIt() async throws {
    let harness = FinishHarness()
    let route = activePharmacyRoute()
    harness.store.route = route

    let result = try #require(await harness.service.finishActiveRoute(outcome: .completed, trigger: .manual))

    #expect(result == RouteFinishResult(
        finished: FinishedRoute(route: route, outcome: .completed, finishedAt: finishNow), trigger: .manual
    ))
    #expect(harness.arbiter.cancelledContexts == [[NavigationInstructionBuilder.contextID(for: route)]])
    #expect(harness.store.route == nil)
    #expect(harness.history.enqueued == [result.finished])
    let message = try #require(harness.arbiter.received.last)
    #expect(message.text == "Navegación finalizada. Llegaste a Farmacia Central.")
    #expect(message.contextID == RouteFinishService.contextID)
    #expect(harness.haptics.cues == [.routeFinished])
}

@Test @MainActor func finishedRouteIsQueuedBeforeTheLocalCopyIsDeleted() async {
    let harness = FinishHarness()
    harness.store.route = activePharmacyRoute()
    var copyExistedWhenQueued = false
    harness.history.onEnqueue = { copyExistedWhenQueued = harness.store.route != nil }

    _ = await harness.service.finishActiveRoute(outcome: .cancelled, trigger: .manual)

    #expect(copyExistedWhenQueued)
}

@Test @MainActor func finishTriesToSaveTheHistoryRightAway() async {
    let harness = FinishHarness()
    harness.store.route = activePharmacyRoute()

    _ = await harness.service.finishActiveRoute(outcome: .completed, trigger: .manual)
    for _ in 0..<20 where harness.history.flushes == 0 { await Task.yield() }

    #expect(harness.history.flushes == 1)
}

@Test(arguments: [
    (RouteFinishTrigger.arrival, RouteHistoryEntry.Outcome.completed, "Llegaste a Farmacia Central. La navegación terminó."),
    (.manual, .cancelled, "Navegación finalizada. La ruta hacia Farmacia Central quedó sin terminar."),
])
@MainActor func finishAnnouncementSaysHowItEnded(
    trigger: RouteFinishTrigger, outcome: RouteHistoryEntry.Outcome, expected: String
) async {
    let harness = FinishHarness()
    harness.store.route = activePharmacyRoute()

    _ = await harness.service.finishActiveRoute(outcome: outcome, trigger: trigger)

    #expect(harness.arbiter.received.last?.text == expected)
}

@Test @MainActor func finishingWithoutActiveRouteSaysSo() async {
    let harness = FinishHarness()

    #expect(await harness.service.finishActiveRoute(outcome: .completed, trigger: .manual) == nil)
    #expect(harness.arbiter.received.map(\.text) == [RouteFinishAnnouncements.noActiveRoute])
    #expect(harness.arbiter.cancelledContexts.isEmpty)
    #expect(harness.haptics.cues.isEmpty)
    #expect(harness.history.enqueued.isEmpty)
}

@Test func finishedScreenTitleDependsOnTheOutcome() {
    let route = activePharmacyRoute()
    let completed = RouteFinishResult(finished: FinishedRoute(route: route, outcome: .completed, finishedAt: finishNow), trigger: .manual)
    let cancelled = RouteFinishResult(finished: FinishedRoute(route: route, outcome: .cancelled, finishedAt: finishNow), trigger: .manual)

    #expect(RouteFinishAnnouncements.title(completed) == "Llegaste a Farmacia Central")
    #expect(RouteFinishAnnouncements.title(cancelled) == "Ruta finalizada")
}

// MARK: - Historial pendiente (SCRUM-130)

@MainActor
private struct HistoryHarness {
    let store = InMemoryFinishedRoutesStore()
    let finishSync = FakeFinishedRouteSync()
    let routeSync = FakeRouteSync()

    var synchronizer: FinishedRouteSynchronizer {
        FinishedRouteSynchronizer(store: store, finishSync: finishSync, routeSync: routeSync)
    }

    func queue(_ routes: ActiveRoute..., outcome: RouteHistoryEntry.Outcome = .completed) -> [FinishedRoute] {
        let finished = routes.map { FinishedRoute(route: $0, outcome: outcome, finishedAt: finishNow) }
        store.routes = finished
        return finished
    }
}

@Test @MainActor func routeKnownByTheBackendIsFinishedById() async throws {
    let harness = HistoryHarness()
    let route = activePharmacyRoute()
    _ = harness.queue(route)

    #expect(await harness.synchronizer.flush())

    let call = try #require(harness.finishSync.finishes.first)
    #expect(call.remoteID == route.remoteID)
    #expect(call.outcome == .completed)
    #expect(call.finishedAt == finishNow)
    #expect(harness.finishSync.records.isEmpty)
    #expect(harness.store.routes.isEmpty)
}

@Test @MainActor func routeThatNeverReachedTheBackendIsRecorded() async {
    let harness = HistoryHarness()
    let queued = harness.queue(activePharmacyRoute(remoteID: nil), outcome: .cancelled)

    #expect(await harness.synchronizer.flush())

    #expect(harness.finishSync.records == queued)
    #expect(harness.finishSync.finishes.isEmpty)
}

@Test @MainActor func pendingDestinationChangeIsSentBeforeFinishing() async {
    let harness = HistoryHarness()
    let route = activePharmacyRoute(pendingChange: true)
    _ = harness.queue(route)

    await harness.synchronizer.flush()

    #expect(harness.routeSync.destinationUpdates.map(\.route) == [route])
    #expect(harness.finishSync.calls == ["finish"])
}

@Test @MainActor func routeClosedInTheBackendIsRecordedWithItsLastDestination() async {
    let harness = HistoryHarness()
    _ = harness.queue(activePharmacyRoute(pendingChange: true))
    harness.routeSync.destinationResult = .failure(ActiveRouteSyncError.routeNoLongerOpen)

    #expect(await harness.synchronizer.flush())

    #expect(harness.finishSync.calls == ["record"])
}

@Test @MainActor func routeMissingInTheBackendIsRecorded() async {
    let harness = HistoryHarness()
    _ = harness.queue(activePharmacyRoute())
    harness.finishSync.finishResults = [.failure(FinishedRouteSyncError.routeNotFound)]

    #expect(await harness.synchronizer.flush())

    #expect(harness.finishSync.calls == ["finish", "record"])
    #expect(harness.store.routes.isEmpty)
}

@Test @MainActor func withoutNetworkTheQueueIsKeptInOrder() async {
    let harness = HistoryHarness()
    let queued = harness.queue(activePharmacyRoute(), activePharmacyRoute())
    harness.finishSync.finishResults = [.failure(URLError(.notConnectedToInternet))]

    #expect(await harness.synchronizer.flush() == false)

    #expect(harness.store.routes == queued)
    #expect(harness.finishSync.finishes.count == 1)
}

@Test @MainActor func expiredSessionKeepsTheQueue() async {
    let harness = HistoryHarness()
    _ = harness.queue(activePharmacyRoute())
    harness.finishSync.finishResults = [.failure(HTTPClientError.statusCode(401))]

    #expect(await harness.synchronizer.flush() == false)
    #expect(harness.store.routes.count == 1)
}

@Test @MainActor func definitiveRejectionIsDroppedSoTheRestIsSent() async {
    let harness = HistoryHarness()
    let queued = harness.queue(activePharmacyRoute(), activePharmacyRoute())
    harness.finishSync.finishResults = [.failure(HTTPClientError.statusCode(422))]

    #expect(await harness.synchronizer.flush())

    #expect(harness.finishSync.finishes.map(\.remoteID) == queued.map(\.route.remoteID))
    #expect(harness.store.routes.isEmpty)
}

@Test @MainActor func idOfAnotherAccountIsDropped() async {
    let harness = HistoryHarness()
    _ = harness.queue(activePharmacyRoute(remoteID: nil))
    harness.finishSync.recordResults = [.failure(FinishedRouteSyncError.idConflict)]

    #expect(await harness.synchronizer.flush())
    #expect(harness.store.routes.isEmpty)
}

@Test @MainActor func queueKeepsOrderAndCanBeDiscarded() throws {
    let harness = HistoryHarness()
    let synchronizer = harness.synchronizer
    let first = FinishedRoute(route: activePharmacyRoute(), outcome: .completed, finishedAt: finishNow)
    let second = FinishedRoute(route: activePharmacyRoute(), outcome: .cancelled, finishedAt: finishNow)

    try synchronizer.enqueue(first)
    try synchronizer.enqueue(second)
    #expect(harness.store.routes == [first, second])

    synchronizer.discardPending()
    #expect(harness.store.routes.isEmpty)
}

@Test @MainActor func flushingTwiceSendsEachRouteOnce() async {
    let harness = HistoryHarness()
    let synchronizer = harness.synchronizer
    _ = harness.queue(activePharmacyRoute())

    async let first = synchronizer.flush()
    async let second = synchronizer.flush()
    _ = await (first, second)

    #expect(harness.finishSync.finishes.count == 1)
}

// MARK: - Orden con el resto del flujo

@Test @MainActor func pendingHistoryIsSentBeforeUploadingANewRoute() async throws {
    let history = SpyPendingHistory()
    let sync = FakeRouteSync()
    var uploadsWhenFlushed: Int?
    history.onFlush = { uploadsWhenFlushed = sync.uploads.count }
    let service = RouteCreationService(
        location: FakeLocationProvider(), geocoder: FakeGeocoder(), calculator: FakeRouteCalculator(),
        store: InMemoryRouteStore(), sync: sync, arbiter: SpyArbiter(), history: history
    )

    _ = try await service.createRoute(to: .query("Farmacia Central"))

    #expect(uploadsWhenFlushed == 0)
    #expect(sync.uploads.count == 1)
}

@Test @MainActor func pendingHistoryIsSentBeforeReadingRecentRoutes() async throws {
    let history = SpyPendingHistory()
    let backend = FakeRouteHistory()
    var fetchesWhenFlushed: Int?
    history.onFlush = { fetchesWhenFlushed = backend.limits.count }
    let service = RecentRoutesService(
        history: backend, store: InMemoryRecentRoutesStore(), arbiter: SpyArbiter(), pendingHistory: history
    )

    _ = try await service.recentRoutes(announce: false)

    #expect(fetchesWhenFlushed == 0)
}

@Test @MainActor func signingOutSendsWhatItCanAndDiscardsTheRest() async {
    let history = SpyPendingHistory()

    await SignOutService(
        session: StoredSessionService(api: nil, store: InMemoryTokenStore(nil)),
        routes: InMemoryRouteStore(), arbiter: nil, pendingHistory: history
    ).signOut()

    #expect(history.flushes == 1)
    #expect(history.discards == 1)
}

// MARK: - Llegada al destino (SCRUM-127)

@MainActor
private struct ArrivalHarness {
    let tracker = FakeLocationTracker()
    let store = InMemoryRouteStore()
    let finisher = FakeRouteFinisher()
    let monitor: ArrivalMonitor

    init(route: ActiveRoute? = activePharmacyRoute()) {
        store.route = route
        finisher.store = store
        monitor = ArrivalMonitor(tracker: tracker, store: store, finisher: finisher)
    }
}

@Test @MainActor func twoPreciseFixesAtTheDestinationFinishTheRoute() async {
    let harness = ArrivalHarness()
    var arrived: RouteFinishResult?
    harness.monitor.onArrival = { arrived = $0 }
    harness.monitor.startMonitoring()

    await harness.monitor.handle(fix(near: pharmacy))
    #expect(harness.finisher.calls.isEmpty)
    await harness.monitor.handle(fix(near: pharmacy, meters: 12))

    #expect(harness.finisher.calls.map(\.outcome) == [.completed])
    #expect(harness.finisher.calls.map(\.trigger) == [.arrival])
    #expect(arrived?.trigger == .arrival)
    #expect(harness.tracker.starts == 1)
    #expect(harness.tracker.stops == 1)
}

@Test @MainActor func inaccurateFixesNeitherCountNorReset() async {
    let harness = ArrivalHarness()
    harness.monitor.startMonitoring()

    await harness.monitor.handle(fix(near: pharmacy))
    await harness.monitor.handle(fix(near: pharmacy, accuracy: 60))
    #expect(harness.finisher.calls.isEmpty)
    await harness.monitor.handle(fix(near: pharmacy))

    #expect(harness.finisher.calls.count == 1)
}

@Test @MainActor func preciseFixAwayFromTheDestinationResetsTheCount() async {
    let harness = ArrivalHarness()
    harness.monitor.startMonitoring()

    await harness.monitor.handle(fix(near: pharmacy))
    await harness.monitor.handle(fix(near: pharmacy, meters: 80))
    await harness.monitor.handle(fix(near: pharmacy))
    #expect(harness.finisher.calls.isEmpty)
    await harness.monitor.handle(fix(near: pharmacy))

    #expect(harness.finisher.calls.count == 1)
}

@Test @MainActor func changingTheDestinationStartsTheCountAgain() async throws {
    let harness = ArrivalHarness()
    harness.monitor.startMonitoring()
    await harness.monitor.handle(fix(near: pharmacy))

    let previous = try #require(harness.store.route)
    harness.store.route = ActiveRoute(
        id: previous.id, remoteID: previous.remoteID, origin: previous.origin, destination: park,
        steps: previous.steps, distanceMeters: 80, expectedTravelTimeSeconds: 70,
        createdAt: previous.createdAt, revision: previous.revision + 1
    )
    await harness.monitor.handle(fix(near: park))
    #expect(harness.finisher.calls.isEmpty)
    await harness.monitor.handle(fix(near: park))

    #expect(harness.finisher.calls.count == 1)
}

@Test @MainActor func withoutActiveRouteNothingIsTracked() async {
    let harness = ArrivalHarness(route: nil)

    harness.monitor.startMonitoring()

    #expect(harness.tracker.starts == 0)
}

@Test @MainActor func routeEndedElsewhereStopsTracking() async {
    let harness = ArrivalHarness()
    harness.monitor.startMonitoring()
    harness.store.route = nil

    await harness.monitor.handle(fix(near: pharmacy))

    #expect(harness.tracker.stops == 1)
    #expect(harness.finisher.calls.isEmpty)
}

@Test @MainActor func stoppedMonitorIgnoresFixes() async {
    let harness = ArrivalHarness()
    harness.monitor.startMonitoring()
    harness.monitor.stopMonitoring()

    await harness.monitor.handle(fix(near: pharmacy))
    await harness.monitor.handle(fix(near: pharmacy))

    #expect(harness.finisher.calls.isEmpty)
}

@Test func invalidFixCannotDecide() {
    let policy = ArrivalPolicy()

    #expect(policy.isNearDestination(fix(near: pharmacy, accuracy: -1), destination: pharmacy) == nil)
    #expect(policy.isNearDestination(fix(near: pharmacy, meters: 24), destination: pharmacy) == true)
    #expect(policy.isNearDestination(fix(near: pharmacy, meters: 30), destination: pharmacy) == false)
}

// MARK: - Contrato del backend

private func jsonBody(_ request: URLRequest?) throws -> [String: Any] {
    let data = try #require(request?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func backendDatesAreSentInUTCWithMilliseconds() {
    #expect(BackendDate.string(from: Date(timeIntervalSince1970: 1_794_132_000.25)) == "2026-11-08T10:00:00.250Z")
}

@Test @MainActor func finishRequestFollowsTheBackendContract() async throws {
    let http = FakeHTTPClient(response: .success(Data("{}".utf8)))
    let service = RemoteFinishedRouteService(client: http, baseURL: URL(string: "http://localhost:8000")!)
    let remoteID = UUID()

    try await service.finish(remoteID: remoteID, outcome: .completed, finishedAt: finishNow)

    let request = try #require(http.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/places/routes/\(remoteID.uuidString.lowercased())/finish")
    let body = try jsonBody(request)
    #expect(body["status"] as? String == "completed")
    #expect(body["finished_at"] as? String == "2026-11-08T10:20:00.000Z")
}

@Test @MainActor func finishOfAMissingRouteIsReported() async {
    let http = FakeHTTPClient(response: .failure(HTTPClientError.statusCode(404)))
    let service = RemoteFinishedRouteService(client: http, baseURL: URL(string: "http://localhost:8000")!)

    await #expect(throws: FinishedRouteSyncError.routeNotFound) {
        try await service.finish(remoteID: UUID(), outcome: .completed, finishedAt: finishNow)
    }
}

@Test @MainActor func offlineRouteIsSentWholeWithItsPhoneId() async throws {
    let http = FakeHTTPClient(response: .success(Data("{}".utf8)))
    let service = RemoteFinishedRouteService(client: http, baseURL: URL(string: "http://localhost:8000")!)
    let route = activePharmacyRoute(remoteID: nil)

    try await service.record(FinishedRoute(route: route, outcome: .cancelled, finishedAt: finishNow))

    let request = try #require(http.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/places/routes/history")
    let body = try jsonBody(request)
    #expect(body["id"] as? String == route.id.uuidString.lowercased())
    #expect(body["status"] as? String == "cancelled")
    #expect(body["started_at"] as? String == "2026-11-08T10:00:00.000Z")
    #expect(body["finished_at"] as? String == "2026-11-08T10:20:00.000Z")
    #expect((body["destination"] as? [String: Any])?["name"] as? String == "Farmacia Central")
    #expect((body["steps"] as? [Any])?.count == route.steps.count)
    #expect(body["distance_meters"] as? Double == 320)
}

@Test @MainActor func offlineRouteWithAnotherAccountsIdIsReported() async {
    let http = FakeHTTPClient(response: .failure(HTTPClientError.statusCode(409)))
    let service = RemoteFinishedRouteService(client: http, baseURL: URL(string: "http://localhost:8000")!)

    await #expect(throws: FinishedRouteSyncError.idConflict) {
        try await service.record(FinishedRoute(route: activePharmacyRoute(), outcome: .completed, finishedAt: finishNow))
    }
}

@Test @MainActor func pendingQueueSurvivesOnDisk() throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = FileFinishedRoutesStore(fileURL: fileURL)
    let queued = [FinishedRoute(route: activePharmacyRoute(), outcome: .completed, finishedAt: finishNow)]

    #expect(try store.load().isEmpty)
    try store.save(queued)
    #expect(try FileFinishedRoutesStore(fileURL: fileURL).load() == queued)
    try store.save([])
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test @MainActor func platformsWithoutNavigationCannotFinish() async {
    #expect(await UnavailableNavigationService().finishActiveRoute(outcome: .completed, trigger: .manual) == nil)
}
