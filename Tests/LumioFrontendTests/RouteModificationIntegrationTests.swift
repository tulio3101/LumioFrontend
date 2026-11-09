import Foundation
import Testing
@testable import LumioFrontend

/// Modificar Ruta integrado con AudioArbiter real, copia local en disco y cliente del
/// backend con sesión (ver IntegratedFlow en RouteCreationIntegrationTests).

private let parkBackendResponse = Data("""
{"id":"\(integrationBackendID.uuidString)","origin":{"name":"Ubicación actual","latitude":4.6097,
"longitude":-74.0817},"destination":{"name":"Parque de los Novios","latitude":4.658,
"longitude":-74.067},"steps":[],"distance_meters":80.0,"expected_travel_time_seconds":70.0,
"current_step":0,"status":"active","started_at":"2026-11-07T15:30:00Z"}
""".utf8)

@Test @MainActor func changedDestinationReplacesInstructionsAudioAndBackendRoute() async throws {
    let flow = IntegratedFlow(backend: .success(integrationBackendResponse))
    defer { flow.cleanUp() }
    let original = try await flow.service.createRoute(to: .query("Farmacia Central"))
    // La primera instrucción de la ruta original sigue esperando turno en la cola.
    #expect(flow.arbiter.pendingMessages.map(\.text) == ["Gira a la derecha en la Calle 19 y continúa 200 metros."])

    flow.geocoder.result = .success(park)
    flow.calculator.result = .success(parkCalculatedRoute())
    flow.http.response = .success(parkBackendResponse)
    let updated = try await flow.modifier.changeDestination(to: .query("Parque de los Novios"))

    // Audio: la instrucción vieja ya no suena; tras lo que se estaba diciendo llegan
    // «Ruta actualizada» y la primera instrucción nueva.
    #expect(!flow.arbiter.pendingMessages.contains { $0.text.hasPrefix("Gira a la derecha") })
    flow.player.finish()
    #expect(flow.arbiter.currentMessage?.text
        == "Ruta actualizada hacia Parque de los Novios. Son 80 metros, alrededor de 1 minuto caminando.")
    flow.player.finish()
    #expect(flow.arbiter.currentMessage?.text == "Camina hacia el sur por la Calle 19 y continúa 80 metros.")

    // Copia local: misma ruta, nueva revisión, sin cambios pendientes.
    let stored = try #require(try flow.storedRoute)
    #expect(stored.id == original.id)
    #expect(stored.revision == 1)
    #expect(stored.destination == park)
    #expect(stored == updated)
    #expect(!stored.isPendingBackendSync)

    // Backend: la misma ruta remota recibe el nuevo recorrido.
    let change = try #require(flow.http.requests.last)
    #expect(change.httpMethod == "PUT")
    #expect(change.url?.path == "/places/routes/\(integrationBackendID.uuidString.lowercased())/destination")
    #expect(change.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
}

@Test @MainActor func failedChangeKeepsRouteAndSaysSo() async throws {
    let flow = IntegratedFlow(backend: .success(integrationBackendResponse))
    defer { flow.cleanUp() }
    let original = try await flow.service.createRoute(to: .query("Farmacia Central"))
    flow.player.finish()
    flow.player.finish()
    let requestsBefore = flow.http.requests.count

    flow.geocoder.result = .failure(RouteCreationError.destinationNotFound)
    await #expect(throws: RouteCreationError.destinationNotFound) {
        try await flow.modifier.changeDestination(to: .query("Lugar inexistente"))
    }

    #expect(flow.arbiter.currentMessage?.text == "No se pudo cambiar el destino. "
        + "No se encontró el destino indicado. Intenta con otra dirección o lugar. "
        + "Sigues con la ruta hacia Farmacia Central.")
    #expect(try flow.storedRoute == original)
    #expect(flow.http.requests.count == requestsBefore)
}
