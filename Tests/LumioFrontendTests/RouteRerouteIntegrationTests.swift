import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

/// Recalcular Ruta integrado: lecturas de GPS → RouteDeviationMonitor → RouteRerouteService
/// con AudioArbiter real, copia local en disco y cliente del backend con sesión (ver
/// IntegratedFlow en RouteCreationIntegrationTests).

/// Reloj que la prueba adelanta para pasar la espera entre recálculos.
@MainActor
private final class ClockBox {
    var now = finishNow
}

@MainActor
private final class RerouteFlow {
    let flow: IntegratedFlow
    let tracker = FakeLocationTracker()
    let connectivity = FakeConnectivity()
    let rerouter: RouteRerouteService
    let monitor: RouteDeviationMonitor
    private let clockBox = ClockBox()
    var clock: Date {
        get { clockBox.now }
        set { clockBox.now = newValue }
    }

    init(backend: Result<Data, Error> = .success(integrationBackendResponse)) {
        flow = IntegratedFlow(backend: backend)
        let baseURL = URL(string: "http://localhost:8000")!
        let authorized = AuthorizedHTTPClient(
            base: flow.http, api: AuthAPI(client: flow.http, baseURL: baseURL), store: flow.tokens
        )
        let store = FileActiveRouteStore(fileURL: flow.fileURL)
        rerouter = RouteRerouteService(
            location: flow.location, geocoder: flow.geocoder, calculator: flow.calculator,
            store: store, sync: RemoteActiveRouteService(client: authorized, baseURL: baseURL),
            arbiter: flow.arbiter, connectivity: connectivity
        )
        monitor = RouteDeviationMonitor(
            tracker: tracker, store: store, rerouter: rerouter, connectivity: connectivity,
            now: { [clockBox] in clockBox.now }
        )
    }

    /// Crea la ruta hacia la farmacia, deja sonar sus anuncios y prepara el recálculo.
    func startRoute() async throws -> ActiveRoute {
        let route = try await flow.service.createRoute(to: .query("Farmacia Central"))
        flow.player.finish()
        flow.player.finish()
        flow.location.result = .success(deviatedPosition)
        flow.calculator.result = .success(rerouteCalculatedRoute())
        monitor.startMonitoring()
        return route
    }

    func walkOffRoute(fixes: Int = 3) async {
        for _ in 0..<fixes { await monitor.handle(fix(offRouteMeters: 60)) }
    }

    /// Lo que suena ahora y lo que espera turno, en orden.
    var spoken: [String] {
        [flow.arbiter.currentMessage?.text].compactMap { $0 } + flow.arbiter.pendingMessages.map(\.text)
    }
}

@Test @MainActor func deviationIsDetectedRecalculatedSpokenStoredAndPersisted() async throws {
    let flow = RerouteFlow()
    defer { flow.flow.cleanUp() }
    let original = try await flow.startRoute()
    flow.flow.http.response = .success(integrationBackendResponse)

    // Dos lecturas fuera del trayecto todavía no bastan.
    await flow.walkOffRoute(fixes: 2)
    #expect(try flow.flow.storedRoute == original)
    await flow.walkOffRoute(fixes: 1)

    // Audio: primero el aviso, después la ruta nueva y su primera instrucción.
    #expect(flow.spoken == [
        "Te saliste de la ruta. Recalculando.",
        "Ruta recalculada hacia Farmacia Central. Son 410 metros, unos 6 minutos caminando.",
        "Camina hacia el este por la Calle 17 y continúa 150 metros.",
    ])

    // Copia local: misma ruta y destino, recorrido nuevo, ya sincronizada.
    let stored = try #require(try flow.flow.storedRoute)
    #expect(stored.id == original.id)
    #expect(stored.destination == original.destination)
    #expect(stored.revision == original.revision + 1)
    #expect(stored.currentStep == 0)
    #expect(stored.steps.first?.instruction == "Camina hacia el este por la Calle 17")
    #expect(!stored.isPendingBackendSync)

    // Backend: PUT /reroute sobre la misma ruta remota, con sesión y la hora del recálculo.
    let request = try #require(flow.flow.http.requests.last)
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.path == "/places/routes/\(integrationBackendID.uuidString.lowercased())/reroute")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    #expect((body["destination"] as? [String: Any])?["name"] as? String == "Farmacia Central")
    #expect(body["rerouted_at"] is String)
}

@Test @MainActor func pendingInstructionsOfTheOldPathAreDropped() async throws {
    let flow = RerouteFlow()
    defer { flow.flow.cleanUp() }
    let original = try await flow.startRoute()
    // Una indicación del recorrido anterior espera turno detrás de otra que suena.
    let builder = NavigationInstructionBuilder()
    flow.flow.arbiter.receive(builder.message(for: original.steps[0], in: original, now: finishNow))
    flow.flow.arbiter.receive(builder.message(for: original.steps[1], in: original, now: finishNow))

    await flow.walkOffRoute()

    #expect(!flow.flow.arbiter.pendingMessages.contains { $0.text.hasPrefix("El destino está a la izquierda") })
    #expect(flow.flow.arbiter.pendingMessages.contains { $0.text.hasPrefix("Ruta recalculada") })
}

@Test @MainActor func withoutConnectionItKeepsGuidingAndRecalculatesWhenTheConnectionReturns() async throws {
    let flow = RerouteFlow()
    defer { flow.flow.cleanUp() }
    let original = try await flow.startRoute()
    let requestsBefore = flow.flow.http.requests.count
    flow.connectivity.isConnected = false

    await flow.walkOffRoute()

    // Sigue la copia local; se avisa una sola vez aunque siga desviado.
    #expect(try flow.flow.storedRoute == original)
    #expect(flow.flow.http.requests.count == requestsBefore)
    let offline = RerouteAnnouncements.offline(destination: "Farmacia Central")
    #expect(flow.spoken == [offline])
    flow.clock = flow.clock.addingTimeInterval(120)
    await flow.walkOffRoute()
    #expect(flow.spoken == [offline])

    flow.flow.player.finish()
    flow.connectivity.isConnected = true
    await flow.monitor.connectionRestored()

    #expect(flow.spoken.first == "Volvió la conexión. Recalculando la ruta.")
    let stored = try #require(try flow.flow.storedRoute)
    #expect(stored.revision == original.revision + 1)
    #expect(flow.flow.http.requests.last?.url?.path.hasSuffix("/reroute") == true)
}

@Test @MainActor func failedRecalculationIsAnnouncedOnceAndRetriedThreeTimes() async throws {
    let flow = RerouteFlow()
    defer { flow.flow.cleanUp() }
    let original = try await flow.startRoute()
    flow.flow.calculator.result = .failure(RouteCreationError.noRouteAvailable)
    let calculationsBefore = flow.flow.calculator.destinations.count

    await flow.walkOffRoute()
    for _ in 0..<4 {
        flow.clock = flow.clock.addingTimeInterval(21)
        await flow.walkOffRoute(fixes: 1)
    }

    // Primer intento y dos reintentos; después deja de intentar mientras siga desviado.
    #expect(flow.flow.calculator.destinations.count - calculationsBefore == 3)
    #expect(flow.spoken == [
        "Te saliste de la ruta. Recalculando.",
        "No se pudo recalcular la ruta. No hay una ruta peatonal disponible hacia ese destino. "
            + "Sigues con la ruta hacia Farmacia Central.",
    ])
    #expect(try flow.flow.storedRoute == original)
}

@Test @MainActor func reroutedWithoutBackendIsSentWhenTheRouteIsRestored() async throws {
    let flow = RerouteFlow()
    defer { flow.flow.cleanUp() }
    _ = try await flow.startRoute()
    flow.flow.http.response = .failure(URLError(.notConnectedToInternet))

    await flow.walkOffRoute()

    // MapKit respondió pero el backend no: la ruta nueva guía y queda pendiente.
    let pending = try #require(try flow.flow.storedRoute)
    #expect(pending.revision == 1)
    #expect(pending.hasPendingReroute)

    flow.flow.http.response = .success(integrationBackendResponse)
    let restored = try #require(await flow.flow.service.restoreActiveRoute())

    #expect(!restored.isPendingBackendSync)
    #expect(flow.flow.http.requests.last?.url?.path.hasSuffix("/reroute") == true)
    #expect(try flow.flow.storedRoute?.hasPendingReroute == false)
}

@Test @MainActor func manualRerouteWorksWhileFollowingTheRoute() async throws {
    let flow = RerouteFlow()
    defer { flow.flow.cleanUp() }
    let original = try await flow.startRoute()

    let outcome = await flow.monitor.rerouteNow()

    guard case .rerouted(let route)? = outcome else {
        Issue.record("Se esperaba una ruta recalculada, llegó \(String(describing: outcome))")
        return
    }
    #expect(route.id == original.id)
    #expect(flow.spoken.first == "Recalculando la ruta.")
}
