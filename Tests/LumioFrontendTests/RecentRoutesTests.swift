import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

/// Consultar Rutas Recientes (SCRUM-24): agrupación, textos, contrato del backend, copia en
/// el teléfono y servicio.

// MARK: - Dobles (también los usa RecentRoutesIntegrationTests)

let recentNow = Date(timeIntervalSince1970: 1_794_132_000) // 2026-11-08 10:00 UTC

func historyEntry(
    _ place: RoutePlace, minutesAgo: Double, outcome: RouteHistoryEntry.Outcome = .cancelled
) -> RouteHistoryEntry {
    let finished = recentNow.addingTimeInterval(-minutesAgo * 60)
    return RouteHistoryEntry(
        destination: place, outcome: outcome, startedAt: finished.addingTimeInterval(-600), finishedAt: finished
    )
}

@MainActor
final class FakeRouteHistory: RouteHistoryFetching {
    var result: Result<[RouteHistoryEntry], Error> = .success([])
    private(set) var limits: [Int] = []

    func recentHistory(limit: Int) async throws -> [RouteHistoryEntry] {
        limits.append(limit)
        return try result.get()
    }
}

@MainActor
final class InMemoryRecentRoutesStore: RecentRoutesStoring {
    var saved: SavedRecentRoutes?
    private(set) var clears = 0

    func load() throws -> SavedRecentRoutes? { saved }
    func save(_ routes: SavedRecentRoutes) throws { saved = routes }
    func clear() throws {
        clears += 1
        saved = nil
    }
}

private let library = RoutePlace(
    name: "Biblioteca Nacional", coordinate: GeoCoordinate(latitude: 4.6100, longitude: -74.0690)
)

private func place(_ name: String, latitude: Double = 4.6110, longitude: Double = -74.0790) -> RoutePlace {
    RoutePlace(name: name, coordinate: GeoCoordinate(latitude: latitude, longitude: longitude))
}

// MARK: - Agrupación

@Test func repeatedDestinationsAreGroupedNewestFirst() throws {
    let destinations = RecentRoutesPolicy.grouped([
        historyEntry(pharmacy, minutesAgo: 10),
        historyEntry(park, minutesAgo: 60, outcome: .completed),
        historyEntry(pharmacy, minutesAgo: 600, outcome: .completed),
    ])

    #expect(destinations.map(\.place.name) == ["Farmacia Central", "Parque de los Novios"])
    let first = try #require(destinations.first)
    #expect(first.timesUsed == 2)
    // Cuenta la vez más reciente: cuándo fue y cómo terminó.
    #expect(first.lastUsedAt == recentNow.addingTimeInterval(-600))
    #expect(first.lastOutcome == .cancelled)
    #expect(destinations[1].lastOutcome == .completed)
}

@Test func groupingDoesNotTrustTheInputOrder() {
    let destinations = RecentRoutesPolicy.grouped([
        historyEntry(park, minutesAgo: 300),
        historyEntry(library, minutesAgo: 5),
        historyEntry(pharmacy, minutesAgo: 60),
    ])

    #expect(destinations.map(\.place.name) == ["Biblioteca Nacional", "Farmacia Central", "Parque de los Novios"])
}

@Test func sameNameFarApartIsAnotherPlace() {
    let destinations = RecentRoutesPolicy.grouped([
        historyEntry(place("Farmacia Central"), minutesAgo: 1),
        historyEntry(place("Farmacia Central", latitude: 4.6160), minutesAgo: 2), // ~550 m
    ])

    #expect(destinations.count == 2)
}

@Test func sameNameIgnoresCaseAccentsAndSmallGpsDifferences() {
    let destinations = RecentRoutesPolicy.grouped([
        historyEntry(place("Café Libro"), minutesAgo: 1),
        historyEntry(place(" cafe libro", latitude: 4.61108), minutesAgo: 2), // ~9 m
    ])

    #expect(destinations.count == 1)
    #expect(destinations.first?.place.name == "Café Libro")
    #expect(destinations.first?.timesUsed == 2)
}

@Test func differentNamesAtTheSamePointAreDifferentDestinations() {
    let destinations = RecentRoutesPolicy.grouped([
        historyEntry(place("Farmacia Central"), minutesAgo: 1),
        historyEntry(place("Panadería La Espiga"), minutesAgo: 2),
    ])

    #expect(destinations.count == 2)
}

@Test func routeWithoutFinishDateUsesItsStart() {
    let started = recentNow.addingTimeInterval(-3_600)
    let entry = RouteHistoryEntry(destination: pharmacy, outcome: .cancelled, startedAt: started, finishedAt: nil)

    #expect(RecentRoutesPolicy.grouped([entry]).first?.lastUsedAt == started)
}

@Test func plannerShowsFiveRecentsWithoutTheCurrentDestination() {
    let destinations = RecentRoutesPolicy.grouped(
        [historyEntry(pharmacy, minutesAgo: 0)]
            + (1...7).map { historyEntry(place("Lugar \($0)", latitude: 4.60 + Double($0) / 100), minutesAgo: Double($0)) }
    )

    let planner = RecentRoutesPolicy.plannerDestinations(destinations, excluding: pharmacy)

    #expect(planner.count == RecentRoutesPolicy.plannerLimit)
    #expect(!planner.contains { $0.place.name == "Farmacia Central" })
    #expect(planner.first?.place.name == "Lugar 1")
    #expect(RecentRoutesPolicy.plannerDestinations(destinations, excluding: nil).first?.place.name == "Farmacia Central")
}

// MARK: - Textos

@Test func announcementSaysHowManyAndTheMostRecent() {
    let destinations = RecentRoutesPolicy.grouped([
        historyEntry(park, minutesAgo: 5), historyEntry(pharmacy, minutesAgo: 50), historyEntry(library, minutesAgo: 90),
    ])

    #expect(RecentRoutesAnnouncements.text(for: RecentRoutes(destinations: destinations, source: .backend))
        == "Tienes 3 destinos recientes. El más reciente es Parque de los Novios.")
    #expect(RecentRoutesAnnouncements.text(for: RecentRoutes(destinations: [destinations[1]], source: .backend))
        == "Tienes 1 destino reciente: Farmacia Central.")
}

@Test func announcementWithoutRecentRoutesSaysSo() {
    #expect(RecentRoutesAnnouncements.text(for: RecentRoutes(destinations: [], source: .backend))
        == "No tienes rutas recientes. Cuando uses una ruta, su destino aparecerá aquí.")
}

@Test func announcementFromTheSavedCopySaysItIsOffline() {
    let destinations = RecentRoutesPolicy.grouped([historyEntry(park, minutesAgo: 5)])

    #expect(RecentRoutesAnnouncements.text(for: RecentRoutes(destinations: destinations, source: .savedCopy(savedAt: recentNow)))
        == "Sin conexión: es la última lista guardada en este teléfono. Tienes 1 destino reciente: Parque de los Novios.")
}

@Test func outcomeAndRepeatsAreReadable() {
    #expect(RecentRoutesAnnouncements.outcome(.completed) == "Completada")
    #expect(RecentRoutesAnnouncements.outcome(.cancelled) == "Sin terminar")
    #expect(RecentRoutesAnnouncements.timesUsed(1) == nil)
    #expect(RecentRoutesAnnouncements.timesUsed(3) == "3 veces")
}

/// Minutos antes de `recentNow`: medio minuto, 1, 5, 1 h, 3 h, 25 h, 3 días, 10 días y un año.
private let minutesAgoCases: [Double] = [0.5, 1, 5, 60, 180, 1_500, 4_320, 14_400, 525_600]
private let lastUseTexts: [String] = [
    "hace un momento", "hace 1 minuto", "hace 5 minutos", "hace 1 hora", "hace 3 horas",
    "ayer", "hace 3 días", "el 29 de octubre", "el 8 de noviembre de 2025",
]

@Test(arguments: zip(minutesAgoCases, lastUseTexts))
func lastUseIsSaidLikeAPerson(minutesAgo: Double, expected: String) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let date = recentNow.addingTimeInterval(-minutesAgo * 60)

    #expect(RecentRoutesAnnouncements.lastUsed(date, now: recentNow, calendar: calendar) == expected)
}

// MARK: - Contrato del backend

@Test(arguments: zip(
    [
        "2026-11-08T10:00:00Z",
        "2026-11-08T10:00:00.250000Z",
        "2026-11-08T10:00:00.5+00:00",
        "2026-11-08T05:00:00-05:00",
    ],
    [0.0, 0.25, 0.5, 0.0]
))
func backendDatesAreParsed(text: String, fraction: Double) throws {
    let date = try #require(BackendDate.parse(text))
    #expect(abs(date.timeIntervalSince(recentNow) - fraction) < 0.000_1)
}

@Test func unreadableBackendDateIsRejected() {
    #expect(BackendDate.parse("ayer") == nil)
}

private let historyResponse = Data("""
{"items":[
 {"id":"\(UUID().uuidString)","origin":{"name":"Ubicación actual","latitude":4.6097,"longitude":-74.0817},
  "destination":{"name":"Parque de los Novios","latitude":4.658,"longitude":-74.067},
  "status":"cancelled","started_at":"2026-11-08T09:20:00.123456Z","finished_at":"2026-11-08T09:30:00.123456Z"},
 {"id":"\(UUID().uuidString)","origin":{"name":"Ubicación actual","latitude":4.6097,"longitude":-74.0817},
  "destination":{"name":"Farmacia Central","latitude":4.611,"longitude":-74.079},
  "status":"completed","started_at":"2026-11-07T18:00:00Z","finished_at":null},
 {"id":"\(UUID().uuidString)","origin":{"name":"Ubicación actual","latitude":4.6097,"longitude":-74.0817},
  "destination":{"name":"Raro","latitude":4.6,"longitude":-74.0},
  "status":"active","started_at":"2026-11-08T09:40:00Z","finished_at":null}
],"total":3,"limit":50,"offset":0}
""".utf8)

@Test @MainActor func historyRequestFollowsTheBackendContract() async throws {
    let http = FakeHTTPClient(response: .success(historyResponse))
    let service = RemoteRouteHistoryService(client: http, baseURL: URL(string: "http://localhost:8000")!)

    let entries = try await service.recentHistory(limit: 50)

    let request = try #require(http.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "http://localhost:8000/places/routes/history?limit=50")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    // La ruta con un estado que no es de historial se omite.
    #expect(entries.map(\.destination.name) == ["Parque de los Novios", "Farmacia Central"])
    #expect(entries[0].outcome == .cancelled)
    #expect(entries[0].destination.coordinate == GeoCoordinate(latitude: 4.658, longitude: -74.067))
    #expect(entries[1].outcome == .completed)
    #expect(entries[1].finishedAt == nil)
}

@Test @MainActor func historyWithoutBaseURLIsNotConfigured() async {
    let service = RemoteRouteHistoryService(client: FakeHTTPClient(response: .success(Data())), baseURL: nil)

    await #expect(throws: RemoteRouteError.notConfigured) {
        try await service.recentHistory(limit: 50)
    }
}

// MARK: - Copia en el teléfono

@Test @MainActor func savedRecentRoutesSurviveOnDiskAndCanBeCleared() throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = FileRecentRoutesStore(fileURL: fileURL)
    let saved = SavedRecentRoutes(
        destinations: RecentRoutesPolicy.grouped([historyEntry(park, minutesAgo: 5)]), savedAt: recentNow
    )

    #expect(try store.load() == nil)
    try store.save(saved)
    #expect(try FileRecentRoutesStore(fileURL: fileURL).load() == saved)
    try store.clear()
    #expect(try store.load() == nil)
}

// MARK: - Servicio

@MainActor
private struct RecentHarness {
    let history = FakeRouteHistory()
    let store = InMemoryRecentRoutesStore()
    let arbiter = SpyArbiter()

    var service: RecentRoutesService {
        RecentRoutesService(history: history, store: store, arbiter: arbiter, now: { recentNow })
    }
}

@Test @MainActor func backendHistoryIsGroupedSavedAndSpoken() async throws {
    let harness = RecentHarness()
    harness.history.result = .success([historyEntry(park, minutesAgo: 5), historyEntry(park, minutesAgo: 90)])

    let routes = try await harness.service.recentRoutes(announce: true)

    #expect(routes.source == .backend)
    #expect(routes.destinations.map(\.timesUsed) == [2])
    #expect(harness.history.limits == [RecentRoutesPolicy.fetchLimit])
    #expect(harness.store.saved == SavedRecentRoutes(destinations: routes.destinations, savedAt: recentNow))
    let message = try #require(harness.arbiter.received.first)
    #expect(harness.arbiter.received.count == 1)
    #expect(message.text == "Tienes 1 destino reciente: Parque de los Novios.")
    #expect(message.priority == .routeInformation)
    #expect(message.contextID == RecentRoutesService.contextID)
    #expect(message.deduplicationKey == "recent-routes")
}

@Test @MainActor func emptyHistoryIsSpokenAndSaved() async throws {
    let harness = RecentHarness()

    let routes = try await harness.service.recentRoutes(announce: true)

    #expect(routes.destinations.isEmpty)
    #expect(harness.store.saved?.destinations == [])
    #expect(harness.arbiter.received.map(\.text) == [RecentRoutesAnnouncements.empty])
}

@Test @MainActor func silentLoadDoesNotSpeak() async throws {
    let harness = RecentHarness()
    harness.history.result = .success([historyEntry(park, minutesAgo: 5)])

    _ = try await harness.service.recentRoutes(announce: false)

    #expect(harness.arbiter.received.isEmpty)
    #expect(harness.store.saved != nil)
}

@Test @MainActor func withoutBackendTheSavedCopyIsUsed() async throws {
    let harness = RecentHarness()
    let savedAt = recentNow.addingTimeInterval(-7_200)
    harness.store.saved = SavedRecentRoutes(
        destinations: RecentRoutesPolicy.grouped([historyEntry(library, minutesAgo: 200)]), savedAt: savedAt
    )
    harness.history.result = .failure(URLError(.notConnectedToInternet))

    let routes = try await harness.service.recentRoutes(announce: true)

    #expect(routes.source == .savedCopy(savedAt: savedAt))
    #expect(routes.destinations.map(\.place.name) == ["Biblioteca Nacional"])
    #expect(harness.arbiter.received.first?.text.hasPrefix(RecentRoutesAnnouncements.savedCopyNote) == true)
}

@Test(arguments: [true, false])
@MainActor func withoutBackendNorCopyTheFailureIsReported(announce: Bool) async {
    let harness = RecentHarness()
    harness.history.result = .failure(RemoteRouteError.notConfigured)

    await #expect(throws: RecentRoutesError.unavailable) {
        try await harness.service.recentRoutes(announce: announce)
    }
    #expect(harness.arbiter.received.map(\.text) == (announce ? [RecentRoutesAnnouncements.unavailable] : []))
}

@Test @MainActor func signingOutClearsTheSavedRecentRoutes() async {
    let recents = InMemoryRecentRoutesStore()
    recents.saved = SavedRecentRoutes(destinations: [], savedAt: recentNow)

    await SignOutService(
        session: StoredSessionService(api: nil, store: InMemoryTokenStore(nil)),
        routes: InMemoryRouteStore(),
        arbiter: nil,
        recentRoutes: recents
    ).signOut()

    #expect(recents.saved == nil)
    #expect(recents.clears == 1)
}

@Test @MainActor func platformsWithoutNavigationHaveNoRecentRoutes() async throws {
    #expect(try await UnavailableNavigationService().recentRoutes(announce: true).destinations.isEmpty)
}
