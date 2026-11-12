import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

/// Consultar Ruta integrado con AudioArbiter real y copia local en disco (ver IntegratedFlow
/// en RouteCreationIntegrationTests). El backend está caído en todas: la consulta no lo usa.

@MainActor
private func statusService(for flow: IntegratedFlow) -> RouteStatusService {
    RouteStatusService(
        store: FileActiveRouteStore(fileURL: flow.fileURL), location: flow.location, arbiter: flow.arbiter
    )
}

@MainActor
private func finishAudio(_ flow: IntegratedFlow) {
    for _ in 0..<5 where flow.arbiter.currentMessage != nil { flow.player.finish() }
}

@Test @MainActor func statusIsSpokenFromTheLocalCopyWithoutBackend() async throws {
    let flow = IntegratedFlow(backend: .failure(URLError(.notConnectedToInternet)))
    defer { flow.cleanUp() }
    let route = try await flow.service.createRoute(to: .query("Farmacia Central"))
    #expect(route.isPendingBackendSync)
    finishAudio(flow)
    let requestsBefore = flow.http.requests.count

    let status = await statusService(for: flow).queryActiveRoute()

    #expect(flow.arbiter.currentMessage?.text == RouteStatusAnnouncements.text(for: status))
    #expect(flow.arbiter.currentMessage?.text.hasPrefix("Vas hacia Farmacia Central. Estás al inicio del recorrido") == true)
    #expect(flow.arbiter.currentMessage?.text.hasSuffix("Siguiente indicación en 120 metros: Gira a la derecha en la Calle 19.") == true)
    // Ninguna petición nueva al backend.
    #expect(flow.http.requests.count == requestsBefore)
}

@Test @MainActor func withoutLocalCopyTheAnswerIsThatThereIsNoRoute() async {
    let flow = IntegratedFlow(backend: .failure(URLError(.notConnectedToInternet)))
    defer { flow.cleanUp() }

    #expect(await statusService(for: flow).queryActiveRoute() == .noActiveRoute)
    #expect(flow.arbiter.currentMessage?.text == RouteStatusAnnouncements.noActiveRoute)
}

@Test @MainActor func corruptLocalCopyIsReportedByAudio() async throws {
    let flow = IntegratedFlow(backend: .failure(URLError(.notConnectedToInternet)))
    defer { flow.cleanUp() }
    try FileManager.default.createDirectory(
        at: flow.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("no es json".utf8).write(to: flow.fileURL)

    #expect(await statusService(for: flow).queryActiveRoute() == .unreadable)
    #expect(flow.arbiter.currentMessage?.text == RouteStatusAnnouncements.unreadable)
}

@Test @MainActor func repeatedQueryWhileTheAnswerIsPlayingIsNotDuplicated() async throws {
    let flow = IntegratedFlow(backend: .failure(URLError(.notConnectedToInternet)))
    defer { flow.cleanUp() }
    _ = try await flow.service.createRoute(to: .query("Farmacia Central"))
    finishAudio(flow)
    let service = statusService(for: flow)

    _ = await service.queryActiveRoute()
    _ = await service.queryActiveRoute()

    #expect(flow.arbiter.currentMessage?.text.hasPrefix("Vas hacia Farmacia Central.") == true)
    #expect(flow.arbiter.pendingMessages.isEmpty)
}

@Test @MainActor func pendingAnswerAboutTheOldDestinationIsDroppedWhenItChanges() async throws {
    let flow = IntegratedFlow(backend: .failure(URLError(.notConnectedToInternet)))
    defer { flow.cleanUp() }
    _ = try await flow.service.createRoute(to: .query("Farmacia Central"))
    // «Ruta lista» suena; la consulta queda esperando turno.
    _ = await statusService(for: flow).queryActiveRoute()
    #expect(flow.arbiter.pendingMessages.contains { $0.text.hasPrefix("Vas hacia Farmacia Central.") })

    flow.geocoder.result = .success(park)
    flow.calculator.result = .success(parkCalculatedRoute())
    _ = try await flow.modifier.changeDestination(to: .query("Parque de los Novios"))

    #expect(!flow.arbiter.pendingMessages.contains { $0.text.hasPrefix("Vas hacia Farmacia Central.") })

    finishAudio(flow)
    _ = await statusService(for: flow).queryActiveRoute()
    #expect(flow.arbiter.currentMessage?.text.hasPrefix("Vas hacia Parque de los Novios.") == true)
}
