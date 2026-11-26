import Foundation
import Testing
@testable import LumioFrontend

// Pantalla Principal Accesible: al abrir, la app informa por audio la sesión, los permisos,
// la seguridad y la ruta activa, una sola vez y como P2. Sin red ni permisos reales.

private struct FakeSession: SessionRestoring {
    var active = true
    func hasActiveSession() -> Bool { active }
}

@MainActor
private final class FakePermissionStatuses: PermissionStatusReading {
    var values: [AppPermission: PermissionStatus]
    init(_ values: [AppPermission: PermissionStatus]) { self.values = values }
    func statuses() async -> [AppPermission: PermissionStatus] { values }
}

private struct FakeSafetyModel: SafetyModelChecking {
    var available = true
    func isModelAvailable() -> Bool { available }
}

private let allAuthorized: [AppPermission: PermissionStatus] = Dictionary(
    uniqueKeysWithValues: AppPermission.allCases.map { ($0, .authorized) }
)

@MainActor
private func makeService(
    signedIn: Bool = true,
    permissions: [AppPermission: PermissionStatus] = allAuthorized,
    modelAvailable: Bool = true,
    routes: InMemoryRouteStore,
    arbiter: SpyArbiter
) -> HomeStatusService {
    HomeStatusService(
        session: FakeSession(active: signedIn),
        permissions: FakePermissionStatuses(permissions),
        safetyModel: FakeSafetyModel(available: modelAvailable),
        routes: routes,
        arbiter: arbiter
    )
}

@Test @MainActor func launchAnnouncesSessionPermissionsAndSafetyOnce() async {
    let arbiter = SpyArbiter()
    let service = makeService(routes: InMemoryRouteStore(), arbiter: arbiter)

    let first = await service.announceOnLaunch()
    let second = await service.announceOnLaunch()

    #expect(second == nil)
    #expect(arbiter.received.count == 1)
    let message = arbiter.received.first
    #expect(message?.text == first)
    #expect(message?.priority == .routeInformation)
    #expect(message?.contextID == HomeStatusService.contextID)
    #expect(first == "Lumio listo. Sesión iniciada. Permisos en orden. "
        + "Detección de obstáculos lista: se activa al iniciar una ruta. "
        + HomeAnnouncements.quickActions)
}

@Test @MainActor func statusCanBeRepeatedOnDemand() async {
    let arbiter = SpyArbiter()
    let service = makeService(routes: InMemoryRouteStore(), arbiter: arbiter)
    _ = await service.announceOnLaunch()

    let again = await service.announce()

    #expect(arbiter.received.map(\.text) == [again, again])
    #expect(arbiter.cancelledContexts.last == [HomeStatusService.contextID])
}

@Test @MainActor func deniedPermissionsAreNamedAndSayWhereToFixThem() async {
    var permissions = allAuthorized
    permissions[.location] = .denied
    permissions[.microphone] = .restricted
    permissions[.speechRecognition] = .notDetermined
    let service = makeService(permissions: permissions, routes: InMemoryRouteStore(), arbiter: SpyArbiter())

    let text = await service.announce()

    // Sin pedir aún: no se menciona (se pide con el flujo accesible al usarlo).
    #expect(text.contains("Falta permiso de ubicación y micrófono. Puedes concederlo en Preferencias, Permisos."))
    #expect(!text.contains("reconocimiento de voz"))
}

@Test @MainActor func safetyIsReportedWhenItCannotStart() async {
    var permissions = allAuthorized
    permissions[.camera] = .denied
    let noCamera = makeService(permissions: permissions, routes: InMemoryRouteStore(), arbiter: SpyArbiter())
    let noModel = makeService(modelAvailable: false, routes: InMemoryRouteStore(), arbiter: SpyArbiter())

    let cameraSnapshot = await noCamera.snapshot()
    let modelSnapshot = await noModel.snapshot()
    let cameraText = await noCamera.announce()
    let modelText = await noModel.announce()

    #expect(cameraSnapshot.safety == .cameraDenied)
    #expect(modelSnapshot.safety == .modelMissing)
    #expect(cameraText.contains("falta permiso de cámara"))
    #expect(modelText.contains("no disponible en esta versión"))
}

@Test @MainActor func activeRouteAndGuestModeAreMentioned() async {
    let routes = InMemoryRouteStore()
    let route = RouteModificationHarness().storeActiveRoute()
    routes.route = route
    let service = makeService(signedIn: false, routes: routes, arbiter: SpyArbiter())

    let text = await service.announce()

    #expect(text.contains("Sin sesión: las rutas no se guardan en el servidor."))
    #expect(text.contains("Tienes una ruta activa a \(route.destination.name)."))
}

@Test func listJoinsWithCommasAndY() {
    #expect(HomeAnnouncements.list([]) == "")
    #expect(HomeAnnouncements.list(["a"]) == "a")
    #expect(HomeAnnouncements.list(["a", "b"]) == "a y b")
    #expect(HomeAnnouncements.list(["a", "b", "c"]) == "a, b y c")
}
