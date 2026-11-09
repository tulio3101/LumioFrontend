import Foundation
import Testing
@testable import LumioFrontend

/// Integración de Crear Ruta y Modificar Ruta con las piezas reales del cliente:
/// AudioArbiter, copia local en disco, cliente del backend con sesión (Bearer y refresh).
/// Solo se simulan los servicios del sistema (GPS, MapKit, síntesis de voz) y la red.
@MainActor
struct IntegratedFlow {
    let player = FakeAudioPlayer()
    let arbiter: AudioArbiterService
    let location = FakeLocationProvider()
    let geocoder = FakeGeocoder()
    let calculator = FakeRouteCalculator()
    let http: FakeHTTPClient
    let tokens = InMemoryTokenStore(AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
    let fileURL = temporaryFileURL()
    let service: RouteCreationService
    let modifier: RouteModificationService

    init(backend: Result<Data, Error>) {
        arbiter = AudioArbiterService(player: player)
        http = FakeHTTPClient(response: backend)
        let baseURL = URL(string: "http://localhost:8000")!
        let authorized = AuthorizedHTTPClient(
            base: http, api: AuthAPI(client: http, baseURL: baseURL), store: tokens
        )
        let store = FileActiveRouteStore(fileURL: fileURL)
        let sync = RemoteActiveRouteService(client: authorized, baseURL: baseURL)
        service = RouteCreationService(
            location: location, geocoder: geocoder, calculator: calculator,
            store: store, sync: sync, arbiter: arbiter
        )
        modifier = RouteModificationService(
            location: location, geocoder: geocoder, calculator: calculator,
            store: store, sync: sync, arbiter: arbiter
        )
    }

    var storedRoute: ActiveRoute? {
        get throws { try FileActiveRouteStore(fileURL: fileURL).load() }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
}

let integrationBackendID = UUID()
let integrationBackendResponse = Data("""
{"id":"\(integrationBackendID.uuidString)","origin":{"name":"Ubicación actual","latitude":4.6097,
"longitude":-74.0817},"destination":{"name":"Farmacia Central","latitude":4.611,
"longitude":-74.079},"steps":[],"distance_meters":320.0,"expected_travel_time_seconds":260.0,
"current_step":0,"status":"active","started_at":"2026-11-07T15:30:00Z"}
""".utf8)

@Test @MainActor func createdRouteIsSpokenStoredAndPersisted() async throws {
    let flow = IntegratedFlow(backend: .success(integrationBackendResponse))
    defer { flow.cleanUp() }

    let route = try await flow.service.createRoute(to: .query("Farmacia Central"))

    // Audio: el anuncio de ruta lista suena primero; la primera instrucción espera su turno.
    #expect(flow.arbiter.currentMessage?.text
        == "Ruta lista hacia Farmacia Central. Son 320 metros, unos 4 minutos caminando.")
    #expect(flow.arbiter.pendingMessages.map(\.text)
        == ["Gira a la derecha en la Calle 19 y continúa 200 metros."])
    flow.player.finish()
    #expect(flow.arbiter.currentMessage?.priority == .routeInformation)
    #expect(flow.arbiter.currentMessage?.text.hasPrefix("Gira a la derecha") == true)

    // Copia local en disco con el id del backend.
    let stored = try FileActiveRouteStore(fileURL: flow.fileURL).load()
    #expect(stored == route)
    #expect(stored?.remoteID == integrationBackendID)

    // Backend: una única petición PUT, identificada con el access token.
    #expect(flow.http.requests.map(\.httpMethod) == ["PUT"])
    #expect(flow.http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
}

@Test @MainActor func safetyAlertInterruptsAndReadyAnnouncementResumes() async throws {
    let flow = IntegratedFlow(backend: .success(integrationBackendResponse))
    defer { flow.cleanUp() }
    _ = try await flow.service.createRoute(to: .query("Farmacia Central"))

    flow.arbiter.receive(AudioMessage(text: "Obstáculo al frente", priority: .immediateRisk))
    #expect(flow.arbiter.currentMessage?.priority == .immediateRisk)

    flow.player.finish()
    #expect(flow.arbiter.currentMessage?.text.hasPrefix("Ruta lista") == true)
}

@Test @MainActor func unavailableRouteIsSpokenAndLeavesNoLocalCopy() async throws {
    let flow = IntegratedFlow(backend: .success(integrationBackendResponse))
    defer { flow.cleanUp() }
    flow.calculator.result = .failure(RouteCreationError.noRouteAvailable)

    await #expect(throws: RouteCreationError.noRouteAvailable) {
        try await flow.service.createRoute(to: .query("Farmacia Central"))
    }

    #expect(flow.arbiter.currentMessage?.text
        == "No hay una ruta peatonal disponible hacia ese destino.")
    #expect(try FileActiveRouteStore(fileURL: flow.fileURL).load() == nil)
    #expect(flow.http.requests.isEmpty)
}

@Test @MainActor func offlineBackendLeavesRouteUsableAndSyncsLater() async throws {
    let flow = IntegratedFlow(backend: .failure(URLError(.notConnectedToInternet)))
    defer { flow.cleanUp() }

    let route = try await flow.service.createRoute(to: .query("Farmacia Central"))
    #expect(route.isPendingBackendSync)
    #expect(try FileActiveRouteStore(fileURL: flow.fileURL).load()?.isPendingBackendSync == true)

    flow.http.response = .success(integrationBackendResponse)
    let restored = await flow.service.restoreActiveRoute()

    #expect(restored?.remoteID == integrationBackendID)
    #expect(try FileActiveRouteStore(fileURL: flow.fileURL).load()?.remoteID == integrationBackendID)
}

// MARK: - Sesión

private let renewedTokens = Data("""
{"access_token":"access-2","refresh_token":"refresh-2","token_type":"bearer","expires_in":900}
""".utf8)

@Test @MainActor func expiredAccessTokenIsRenewedAndTheRouteIsSaved() async throws {
    let flow = IntegratedFlow(backend: .success(integrationBackendResponse))
    defer { flow.cleanUp() }
    flow.http.queued = [.failure(HTTPClientError.statusCode(401)), .success(renewedTokens)]

    let route = try await flow.service.createRoute(to: .query("Farmacia Central"))

    #expect(route.remoteID == integrationBackendID)
    #expect(flow.http.requests.map { $0.url?.path } == [
        "/places/routes/active", "/users/refresh", "/places/routes/active",
    ])
    #expect(flow.http.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
    #expect(flow.tokens.load() == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
}

@Test @MainActor func rejectedSessionKeepsTheRouteOnThePhone() async throws {
    let flow = IntegratedFlow(backend: .failure(HTTPClientError.statusCode(401)))
    defer { flow.cleanUp() }

    let route = try await flow.service.createRoute(to: .query("Farmacia Central"))

    // La ruta se puede seguir; la sesión se cierra y la ruta queda pendiente de guardar.
    #expect(route.isPendingBackendSync)
    #expect(try flow.storedRoute == route)
    #expect(flow.tokens.load() == nil)
}
