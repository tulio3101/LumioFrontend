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
final class FakeCameraGate: CameraAssistanceGating {
    var authorized: Bool
    private(set) var announcements = 0
    private(set) var modelAnnouncements = 0
    init(authorized: Bool) { self.authorized = authorized }
    func canAssistWithObstacles() async -> Bool { authorized }
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
final class StubPermissionProvider: PermissionProviding {
    var status: PermissionStatus
    init(status: PermissionStatus) { self.status = status }
    func status(for permission: AppPermission) async -> PermissionStatus { status }
    func request(_ permission: AppPermission) async throws -> PermissionStatus { status }
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
        obstacleGate: gate ?? FakeCameraGate(authorized: true)
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

// MARK: - Req 5: sin permiso de cámara la ruta sigue y se avisa una vez

@Test @MainActor func routeContinuesWithoutDetectionWhenCameraDenied() async {
    let safety = SpySafetyMonitor()
    let gate = FakeCameraGate(authorized: false)
    let vm = makeViewModel(creator: FakeRouteCreator(created: activePharmacyRoute()), safety: safety, gate: gate)

    let created = await vm.createRoute(to: .query("Farmacia"))
    await waitUntil { gate.announcements == 1 }

    #expect(created)              // la ruta sigue
    #expect(safety.starts == 0)   // no se arrancó la detección
    #expect(gate.announcements == 1)
}

@Test @MainActor func gateAnnouncesOnceAndChecksCameraPermission() async {
    let arbiter = SpyArbiter()
    let denied = ObstacleAssistanceGate(
        permissions: PermissionService(provider: StubPermissionProvider(status: .denied)),
        audio: arbiter
    )
    #expect(await denied.canAssistWithObstacles() == false)
    denied.announceAssistanceUnavailable()
    denied.announceAssistanceUnavailable()
    #expect(arbiter.received.filter { $0.deduplicationKey == "safety-no-camera" }.count == 1)

    let granted = ObstacleAssistanceGate(
        permissions: PermissionService(provider: StubPermissionProvider(status: .authorized)),
        audio: SpyArbiter()
    )
    #expect(await granted.canAssistWithObstacles() == true)
}

// MARK: - El aviso de "modelo no disponible" suena al iniciar la ruta, no al abrir la app

@Test @MainActor func modelUnavailableIsAnnouncedWhenRouteStartsNotAtLaunch() async {
    let gate = FakeCameraGate(authorized: true)
    let vm = DestinationViewModel(
        routeCreator: FakeRouteCreator(created: activePharmacyRoute()),
        safetyMonitor: nil,     // modelo no cargó → sin monitor
        obstacleGate: gate
    )
    // Construir el ViewModel (abrir la app) no anuncia nada.
    #expect(gate.modelAnnouncements == 0)

    _ = await vm.createRoute(to: .query("Farmacia"))

    #expect(gate.modelAnnouncements == 1)
}

@Test @MainActor func gateAnnouncesModelUnavailableOnlyWhenModelFailed() {
    let failedArbiter = SpyArbiter()
    let failed = ObstacleAssistanceGate(
        permissions: PermissionService(provider: StubPermissionProvider(status: .authorized)),
        audio: failedArbiter, modelAvailable: false
    )
    #expect(failedArbiter.received.isEmpty)   // no suena al construir (abrir la app)
    failed.announceModelUnavailable()
    #expect(failedArbiter.received.filter { $0.deduplicationKey == "safety-unavailable" }.count == 1)

    let okArbiter = SpyArbiter()
    let ok = ObstacleAssistanceGate(
        permissions: PermissionService(provider: StubPermissionProvider(status: .authorized)),
        audio: okArbiter, modelAvailable: true
    )
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
