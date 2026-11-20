#if canImport(SwiftUI)
import Testing
import Foundation
@testable import LumioFrontend

// SCRUM-33: la detección de obstáculos se engancha a la navegación en DestinationViewModel,
// en paralelo a arrivalMonitor: arranca con la ruta (crear/restaurar) y para al finalizar.
// SCRUM-315: con permiso de cámara negado, la ruta sigue y se avisa una sola vez.

// MARK: - Dobles

@MainActor
final class FakeRouteCreator: RouteCreating {
    var created: ActiveRoute
    var restored: ActiveRoute?
    init(created: ActiveRoute, restored: ActiveRoute? = nil) {
        self.created = created
        self.restored = restored
    }
    func createRoute(to destination: DestinationRequest) async throws -> ActiveRoute { created }
    func restoreActiveRoute() async -> ActiveRoute? { restored }
}

@MainActor
final class SpyArrivalMonitor: ArrivalMonitoring {
    var onArrival: (@MainActor (RouteFinishResult) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    func startMonitoring() { starts += 1 }
    func stopMonitoring() { stops += 1 }
}

@MainActor
final class SpySafetyMonitor: SafetyMonitoring {
    var onEvent: ((SafetyEvent) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    func start() async throws { starts += 1 }
    func stop() { stops += 1 }
}

@MainActor
final class SpyDeviationMonitor: RouteDeviationMonitoring {
    var onStatusChange: (@MainActor (RerouteStatus?) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    var rerouteNowResult: RerouteOutcome?
    func startMonitoring() { starts += 1 }
    func stopMonitoring() { stops += 1 }
    func rerouteNow() async -> RerouteOutcome? { rerouteNowResult }
    /// Simula que el monitor detectó un desvío y recalculó (SCRUM-26).
    func fireStatus(_ status: RerouteStatus?) { onStatusChange?(status) }
}

@MainActor
final class FakeCameraGate: CameraAssistanceGating {
    var prepareResult: Bool
    private(set) var prepareCalls = 0
    private(set) var announcements = 0
    private(set) var modelAnnouncements = 0
    init(prepareResult: Bool) { self.prepareResult = prepareResult }
    func prepareObstacleAssistance() async -> Bool { prepareCalls += 1; return prepareResult }
    func announceAssistanceUnavailable() { announcements += 1 }
    func announceModelUnavailable() { modelAnnouncements += 1 }
}

@MainActor
final class StubRouteFinisher: RouteFinishing {
    var result: RouteFinishResult?
    func finishActiveRoute(outcome: RouteHistoryEntry.Outcome, trigger: RouteFinishTrigger) async -> RouteFinishResult? {
        result
    }
}

@MainActor
private func makeViewModel(
    creator: FakeRouteCreator,
    safety: SpySafetyMonitor,
    gate: FakeCameraGate? = nil,
    arrival: SpyArrivalMonitor? = nil,
    finisher: StubRouteFinisher? = nil
) -> DestinationViewModel {
    DestinationViewModel(
        routeCreator: creator,
        routeFinisher: finisher ?? StubRouteFinisher(),
        arrivalMonitor: arrival ?? SpyArrivalMonitor(),
        safetyMonitor: safety,
        obstacleGate: gate ?? FakeCameraGate(prepareResult: true)
    )
}

@MainActor
private func waitUntil(_ condition: () -> Bool, tries: Int = 200) async {
    for _ in 0..<tries where !condition() { await Task.yield() }
}

// MARK: - Req 1: arranca con la ruta, para al finalizar

@Test @MainActor func detectionStartsWhenRouteIsCreated() async {
    let safety = SpySafetyMonitor()
    let vm = makeViewModel(creator: FakeRouteCreator(created: activePharmacyRoute()), safety: safety)

    _ = await vm.createRoute(to: .query("Farmacia"))
    await waitUntil { safety.starts == 1 }

    #expect(safety.starts == 1)
}

@Test @MainActor func detectionStartsWhenRouteIsRestored() async {
    let safety = SpySafetyMonitor()
    let creator = FakeRouteCreator(created: activePharmacyRoute(), restored: activePharmacyRoute())
    let vm = makeViewModel(creator: creator, safety: safety)

    await vm.restoreActiveRoute()
    await waitUntil { safety.starts == 1 }

    #expect(safety.starts == 1)
}

@Test @MainActor func detectionStopsWhenRouteFinishesManually() async {
    let safety = SpySafetyMonitor()
    let finisher = StubRouteFinisher()
    finisher.result = RouteFinishResult(
        finished: FinishedRoute(route: activePharmacyRoute(), outcome: .completed, finishedAt: finishNow),
        trigger: .manual
    )
    let vm = makeViewModel(creator: FakeRouteCreator(created: activePharmacyRoute()), safety: safety, finisher: finisher)
    _ = await vm.createRoute(to: .query("Farmacia"))

    _ = await vm.finishRoute(outcome: .completed)

    #expect(safety.stops >= 1)
}

@Test @MainActor func detectionStopsOnAutomaticArrival() async {
    let safety = SpySafetyMonitor()
    let arrival = SpyArrivalMonitor()
    let vm = makeViewModel(creator: FakeRouteCreator(created: activePharmacyRoute()), safety: safety, arrival: arrival)
    _ = await vm.createRoute(to: .query("Farmacia"))

    let result = RouteFinishResult(
        finished: FinishedRoute(route: activePharmacyRoute(), outcome: .completed, finishedAt: finishNow),
        trigger: .arrival
    )
    arrival.onArrival?(result)

    #expect(safety.stops >= 1)
}

// MARK: - SCRUM-26 + SCRUM-33: recalcular NO detiene ni reinicia la detección

@Test @MainActor func reroutingDoesNotStopOrRestartDetection() async {
    let safety = SpySafetyMonitor()
    let deviation = SpyDeviationMonitor()
    let vm = DestinationViewModel(
        routeCreator: FakeRouteCreator(created: activePharmacyRoute()),
        arrivalMonitor: SpyArrivalMonitor(),
        deviationMonitor: deviation,
        safetyMonitor: safety,
        obstacleGate: FakeCameraGate(prepareResult: true)
    )
    _ = await vm.createRoute(to: .query("Farmacia"))
    await waitUntil { safety.starts == 1 }
    #expect(safety.starts == 1)
    #expect(safety.stops == 0)

    // Recálculo automático: llega un nuevo recorrido por onStatusChange (SCRUM-26).
    deviation.fireStatus(.rerouted(activePharmacyRoute()))
    await Task.yield()
    await Task.yield()

    // Recálculo a mano.
    deviation.rerouteNowResult = .rerouted(activePharmacyRoute())
    _ = await vm.recalculateRoute()
    await Task.yield()

    // La detección sigue corriendo sin tocarse: ni para ni vuelve a arrancar.
    #expect(safety.starts == 1, "recalcular no debe reiniciar la detección")
    #expect(safety.stops == 0, "recalcular no debe detener la detección")
}

// MARK: - Permiso de cámara: concede vs. niega (comportamiento en el ViewModel)

@Test @MainActor func cameraGrantedStartsDetectionWithoutFailure() async {
    let safety = SpySafetyMonitor()
    let gate = FakeCameraGate(prepareResult: true)
    let vm = makeViewModel(creator: FakeRouteCreator(created: activePharmacyRoute()), safety: safety, gate: gate)

    _ = await vm.createRoute(to: .query("Farmacia"))
    await waitUntil { safety.starts == 1 }

    #expect(safety.starts == 1)       // concedido → arranca de inmediato, sin reiniciar la ruta
    #expect(gate.announcements == 0)
    #expect(vm.failure == nil)
}

@Test @MainActor func cameraDeniedContinuesRouteAnnouncesOnceAndOffersSettings() async {
    let safety = SpySafetyMonitor()
    let gate = FakeCameraGate(prepareResult: false)
    let vm = makeViewModel(creator: FakeRouteCreator(created: activePharmacyRoute()), safety: safety, gate: gate)

    let created = await vm.createRoute(to: .query("Farmacia"))
    await waitUntil { gate.announcements == 1 }

    #expect(created)                                // la ruta sigue
    #expect(safety.starts == 0)                     // no se arrancó la detección
    #expect(gate.announcements == 1)                // avisado una sola vez
    #expect(vm.failure?.recovery == .openSettings)  // se ofrece abrir Ajustes
}

// MARK: - Flujo accesible del permiso de cámara en los 4 estados (PermissionsViewModel)

@MainActor
final class ScriptedPermissionProvider: PermissionProviding {
    private var current: PermissionStatus
    private let afterRequest: PermissionStatus
    private(set) var requests = 0
    init(initial: PermissionStatus, afterRequest: PermissionStatus) {
        current = initial
        self.afterRequest = afterRequest
    }
    func status(for permission: AppPermission) async -> PermissionStatus { current }
    func request(_ permission: AppPermission) async throws -> PermissionStatus {
        requests += 1
        current = afterRequest
        return afterRequest
    }
}

/// Reproductor que completa cada mensaje enseguida, para que `receiveAndWait` de `say` no cuelgue.
@MainActor
final class ImmediatePlayer: AudioPlaying {
    var onFinished: ((PlaybackToken) -> Void)?
    private(set) var played: [AudioMessage] = []
    func play(_ message: AudioMessage, token: PlaybackToken) throws {
        played.append(message)
        Task { @MainActor in self.onFinished?(token) }
    }
    func stop() {}
}

@MainActor
private func permissionsViewModel(initial: PermissionStatus, afterRequest: PermissionStatus)
    -> (PermissionsViewModel, ScriptedPermissionProvider, ImmediatePlayer) {
    let provider = ScriptedPermissionProvider(initial: initial, afterRequest: afterRequest)
    let player = ImmediatePlayer()
    let vm = PermissionsViewModel(
        service: PermissionService(provider: provider), audio: AudioArbiterService(player: player)
    )
    return (vm, provider, player)
}

@Test @MainActor func cameraNotDeterminedThenGrantedExplainsAsksAndAssists() async {
    let (pvm, provider, player) = permissionsViewModel(initial: .notDetermined, afterRequest: .authorized)
    let granted = await pvm.requestForObstacleAssistance()
    #expect(granted)
    #expect(provider.requests == 1)                                 // mostró el diálogo del sistema
    #expect(player.played.contains { $0.text.contains("cámara") })  // explicó por audio primero
}

@Test @MainActor func cameraNotDeterminedThenDeniedDoesNotAssist() async {
    let (pvm, provider, _) = permissionsViewModel(initial: .notDetermined, afterRequest: .denied)
    let granted = await pvm.requestForObstacleAssistance()
    #expect(!granted)
    #expect(provider.requests == 1)
}

@Test @MainActor func cameraAlreadyDeniedDoesNotAskNorExplain() async {
    let (pvm, provider, player) = permissionsViewModel(initial: .denied, afterRequest: .denied)
    let granted = await pvm.requestForObstacleAssistance()
    #expect(!granted)
    #expect(provider.requests == 0)   // no vuelve a mostrar el diálogo
    #expect(player.played.isEmpty)    // ni explica
}

@Test @MainActor func cameraAlreadyAuthorizedAssistsWithoutAsking() async {
    let (pvm, provider, player) = permissionsViewModel(initial: .authorized, afterRequest: .authorized)
    let granted = await pvm.requestForObstacleAssistance()
    #expect(granted)
    #expect(provider.requests == 0)
    #expect(player.played.isEmpty)    // no pregunta nada
}

// MARK: - El aviso de "modelo no disponible" suena al iniciar la ruta, no al abrir la app

@Test @MainActor func modelUnavailableIsAnnouncedWhenRouteStartsNotAtLaunch() async {
    let gate = FakeCameraGate(prepareResult: true)
    let vm = DestinationViewModel(
        routeCreator: FakeRouteCreator(created: activePharmacyRoute()),
        safetyMonitor: nil,     // modelo no cargó → sin monitor
        obstacleGate: gate
    )
    #expect(gate.modelAnnouncements == 0)   // abrir la app no anuncia

    _ = await vm.createRoute(to: .query("Farmacia"))

    #expect(gate.modelAnnouncements == 1)   // al iniciar la ruta, sí
}

@Test @MainActor func gateAnnouncesModelUnavailableOnlyWhenModelFailed() {
    let (pvm, _, _) = permissionsViewModel(initial: .authorized, afterRequest: .authorized)
    let failedArbiter = SpyArbiter()
    let failed = ObstacleAssistanceGate(permissions: pvm, audio: failedArbiter, modelAvailable: false)
    #expect(failedArbiter.received.isEmpty)   // no suena al construir (abrir la app)
    failed.announceModelUnavailable()
    #expect(failedArbiter.received.filter { $0.deduplicationKey == "safety-unavailable" }.count == 1)

    let okArbiter = SpyArbiter()
    let ok = ObstacleAssistanceGate(permissions: pvm, audio: okArbiter, modelAvailable: true)
    ok.announceModelUnavailable()
    #expect(okArbiter.received.isEmpty)       // modelo OK: nunca anuncia
}

// MARK: - Req 6: la detección solo corre con una ruta activa (no al lanzar la app)

@Test @MainActor func detectionDoesNotStartWithoutAnActiveRoute() async {
    let safety = SpySafetyMonitor()
    let vm = makeViewModel(
        creator: FakeRouteCreator(created: activePharmacyRoute(), restored: nil),
        safety: safety
    )

    // Restaurar sin ruta guardada: no hay ruta activa, no arranca la detección.
    await vm.restoreActiveRoute()
    await Task.yield()
    await Task.yield()

    #expect(safety.starts == 0)
}
#endif
