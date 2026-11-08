import Foundation
import Testing
@testable import LumioFrontend

/// Integración del flujo Crear Ruta con las piezas reales del cliente: AudioArbiter,
/// copia local en disco y cliente del backend. Solo se simulan los servicios del sistema
/// (GPS, MapKit, síntesis de voz) y la red.
@MainActor
private struct IntegratedFlow {
    let player = FakeAudioPlayer()
    let arbiter: AudioArbiterService
    let location = FakeLocationProvider()
    let geocoder = FakeGeocoder()
    let calculator = FakeRouteCalculator()
    let http: FakeHTTPClient
    let fileURL = temporaryFileURL()
    let service: RouteCreationService

    init(backend: Result<Data, Error>) {
        arbiter = AudioArbiterService(player: player)
        http = FakeHTTPClient(response: backend)
        service = RouteCreationService(
            location: location,
            geocoder: geocoder,
            calculator: calculator,
            store: FileActiveRouteStore(fileURL: fileURL),
            sync: RemoteActiveRouteService(
                client: http, baseURL: URL(string: "http://localhost:8000")!, userID: UUID()
            ),
            arbiter: arbiter
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
}

private let backendID = UUID()
private let backendResponse = Data("""
{"id":"\(backendID.uuidString)","origin":{"name":"Ubicación actual","latitude":4.6097,
"longitude":-74.0817},"destination":{"name":"Farmacia Central","latitude":4.611,
"longitude":-74.079},"steps":[],"distance_meters":320.0,"expected_travel_time_seconds":260.0,
"current_step":0,"status":"active","started_at":"2026-11-07T15:30:00Z"}
""".utf8)

@Test @MainActor func createdRouteIsSpokenStoredAndPersisted() async throws {
    let flow = IntegratedFlow(backend: .success(backendResponse))
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
    #expect(stored?.remoteID == backendID)

    // Backend: una única petición PUT.
    #expect(flow.http.requests.map(\.httpMethod) == ["PUT"])
}

@Test @MainActor func safetyAlertInterruptsAndReadyAnnouncementResumes() async throws {
    let flow = IntegratedFlow(backend: .success(backendResponse))
    defer { flow.cleanUp() }
    _ = try await flow.service.createRoute(to: .query("Farmacia Central"))

    flow.arbiter.receive(AudioMessage(text: "Obstáculo al frente", priority: .immediateRisk))
    #expect(flow.arbiter.currentMessage?.priority == .immediateRisk)

    flow.player.finish()
    #expect(flow.arbiter.currentMessage?.text.hasPrefix("Ruta lista") == true)
}

@Test @MainActor func unavailableRouteIsSpokenAndLeavesNoLocalCopy() async throws {
    let flow = IntegratedFlow(backend: .success(backendResponse))
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

    flow.http.response = .success(backendResponse)
    let restored = await flow.service.restoreActiveRoute()

    #expect(restored?.remoteID == backendID)
    #expect(try FileActiveRouteStore(fileURL: flow.fileURL).load()?.remoteID == backendID)
}
