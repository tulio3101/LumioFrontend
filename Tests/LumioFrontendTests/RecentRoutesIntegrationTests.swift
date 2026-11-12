import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

/// Consultar Rutas Recientes integrado: cliente del backend con sesión (AuthorizedHTTPClient),
/// AudioArbiter real, copia en disco y, al reutilizar un destino, los servicios reales de
/// Crear y Modificar Ruta (ver IntegratedFlow en RouteCreationIntegrationTests).

/// Respuesta como la serializa el backend (Pydantic): UTC con `Z` y microsegundos.
private let historyResponse = Data("""
{"items":[
 {"id":"\(UUID().uuidString)","origin":{"name":"Ubicación actual","latitude":4.6097,"longitude":-74.0817},
  "destination":{"name":"Parque de los Novios","latitude":4.658,"longitude":-74.067},
  "status":"cancelled","started_at":"2026-11-08T09:20:00.123456Z","finished_at":"2026-11-08T09:30:00.654321Z"},
 {"id":"\(UUID().uuidString)","origin":{"name":"Ubicación actual","latitude":4.6097,"longitude":-74.0817},
  "destination":{"name":"Farmacia Central","latitude":4.611,"longitude":-74.079},
  "status":"cancelled","started_at":"2026-11-08T08:00:00.000001Z","finished_at":"2026-11-08T08:15:00.000001Z"},
 {"id":"\(UUID().uuidString)","origin":{"name":"Ubicación actual","latitude":4.6097,"longitude":-74.0817},
  "destination":{"name":"Farmacia Central","latitude":4.611,"longitude":-74.079},
  "status":"completed","started_at":"2026-11-01T17:00:00Z","finished_at":"2026-11-01T17:20:00Z"}
],"total":3,"limit":50,"offset":0}
""".utf8)

@MainActor
private struct RecentFlow {
    let flow: IntegratedFlow
    let recentsURL = temporaryFileURL()
    let service: RecentRoutesService

    init(backend: Result<Data, Error>) {
        flow = IntegratedFlow(backend: backend)
        let baseURL = URL(string: "http://localhost:8000")!
        let authorized = AuthorizedHTTPClient(
            base: flow.http, api: AuthAPI(client: flow.http, baseURL: baseURL), store: flow.tokens
        )
        service = RecentRoutesService(
            history: RemoteRouteHistoryService(client: authorized, baseURL: baseURL),
            store: FileRecentRoutesStore(fileURL: recentsURL),
            arbiter: flow.arbiter
        )
    }

    var savedCopy: SavedRecentRoutes? {
        get throws { try FileRecentRoutesStore(fileURL: recentsURL).load() }
    }

    func cleanUp() {
        flow.cleanUp()
        try? FileManager.default.removeItem(at: recentsURL.deletingLastPathComponent())
    }
}

@Test @MainActor func backendHistoryIsGroupedSpokenAndKeptOnThePhone() async throws {
    let recent = RecentFlow(backend: .success(historyResponse))
    defer { recent.cleanUp() }

    let routes = try await recent.service.recentRoutes(announce: true)

    #expect(routes.source == .backend)
    #expect(routes.destinations.map(\.place.name) == ["Parque de los Novios", "Farmacia Central"])
    #expect(routes.destinations.map(\.timesUsed) == [1, 2])
    #expect(routes.destinations[1].lastOutcome == .cancelled)
    #expect(recent.flow.arbiter.currentMessage?.text
        == "Tienes 2 destinos recientes. El más reciente es Parque de los Novios.")

    let request = try #require(recent.flow.http.requests.last)
    #expect(request.url?.path == "/places/routes/history")
    #expect(request.url?.query == "limit=\(RecentRoutesPolicy.fetchLimit)")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    #expect(try recent.savedCopy?.destinations == routes.destinations)
}

@Test @MainActor func withoutConnectionTheSavedCopyIsShownAndSaidToBeOffline() async throws {
    let recent = RecentFlow(backend: .success(historyResponse))
    defer { recent.cleanUp() }
    let online = try await recent.service.recentRoutes(announce: false)

    recent.flow.http.response = .failure(URLError(.notConnectedToInternet))
    let offline = try await recent.service.recentRoutes(announce: true)

    #expect(offline.destinations == online.destinations)
    guard case .savedCopy = offline.source else {
        Issue.record("Se esperaba la copia guardada, llegó \(offline.source)")
        return
    }
    #expect(recent.flow.arbiter.currentMessage?.text
        == "Sin conexión: es la última lista guardada en este teléfono. "
        + "Tienes 2 destinos recientes. El más reciente es Parque de los Novios.")
}

@Test @MainActor func firstLoadWithoutConnectionIsReportedByAudio() async {
    let recent = RecentFlow(backend: .failure(URLError(.notConnectedToInternet)))
    defer { recent.cleanUp() }

    await #expect(throws: RecentRoutesError.unavailable) {
        try await recent.service.recentRoutes(announce: true)
    }
    #expect(recent.flow.arbiter.currentMessage?.text == RecentRoutesAnnouncements.unavailable)
}

@Test @MainActor func emptyHistoryIsReportedByAudio() async throws {
    let recent = RecentFlow(backend: .success(Data(#"{"items":[],"total":0,"limit":50,"offset":0}"#.utf8)))
    defer { recent.cleanUp() }

    let routes = try await recent.service.recentRoutes(announce: true)

    #expect(routes.destinations.isEmpty)
    #expect(recent.flow.arbiter.currentMessage?.text == RecentRoutesAnnouncements.empty)
}

@Test @MainActor func recentDestinationStartsANewRouteWithoutSearchingAgain() async throws {
    let recent = RecentFlow(backend: .success(historyResponse))
    defer { recent.cleanUp() }
    let destination = try #require(try await recent.service.recentRoutes(announce: false).destinations.first)
    recent.flow.calculator.result = .success(parkCalculatedRoute())
    recent.flow.http.response = .success(integrationBackendResponse)

    let route = try await recent.flow.service.createRoute(to: .place(destination.place))

    // El lugar del historial se usa tal cual: no se vuelve a geocodificar.
    #expect(recent.flow.geocoder.queries.isEmpty)
    #expect(route.destination == destination.place)
    #expect(recent.flow.calculator.destinations == [destination.place])
    #expect(recent.flow.arbiter.currentMessage?.text.hasPrefix("Ruta lista hacia Parque de los Novios.") == true)
}

@Test @MainActor func recentDestinationChangesTheActiveRoute() async throws {
    let recent = RecentFlow(backend: .success(integrationBackendResponse))
    defer { recent.cleanUp() }
    let active = try await recent.flow.service.createRoute(to: .query("Farmacia Central"))
    recent.flow.http.response = .success(historyResponse)
    let destination = try #require(try await recent.service.recentRoutes(announce: false).destinations.first)
    recent.flow.calculator.result = .success(parkCalculatedRoute())
    recent.flow.http.response = .success(integrationBackendResponse)

    let changed = try await recent.flow.modifier.changeDestination(to: .place(destination.place))

    #expect(changed.id == active.id)
    #expect(changed.revision == active.revision + 1)
    #expect(changed.destination == destination.place)
    #expect(recent.flow.geocoder.queries == ["Farmacia Central"])
}

@Test @MainActor func signingOutDeletesTheSavedRecentRoutes() async throws {
    let recent = RecentFlow(backend: .success(historyResponse))
    defer { recent.cleanUp() }
    _ = try await recent.service.recentRoutes(announce: false)
    #expect(try recent.savedCopy != nil)

    await SignOutService(
        session: StoredSessionService(api: nil, store: recent.flow.tokens),
        routes: FileActiveRouteStore(fileURL: recent.flow.fileURL),
        arbiter: recent.flow.arbiter,
        recentRoutes: FileRecentRoutesStore(fileURL: recent.recentsURL)
    ).signOut()

    #expect(try recent.savedCopy == nil)
}
