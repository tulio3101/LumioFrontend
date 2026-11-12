import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

private func sampleRoute(remoteID: UUID? = nil) -> ActiveRoute {
    ActiveRoute(
        id: UUID(),
        remoteID: remoteID,
        origin: RoutePlace(name: "Ubicación actual", coordinate: currentPosition),
        destination: pharmacy,
        steps: NavigationInstructionBuilder().steps(from: sampleCalculatedRoute().steps),
        distanceMeters: 320,
        expectedTravelTimeSeconds: 260,
        createdAt: Date(timeIntervalSince1970: 1_000)
    )
}

// MARK: - Copia local

@Test @MainActor func localCopySurvivesAReload() throws {
    let url = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let route = sampleRoute(remoteID: UUID())

    try FileActiveRouteStore(fileURL: url).save(route)

    #expect(try FileActiveRouteStore(fileURL: url).load() == route)
}

@Test @MainActor func localCopyIsReplacedAndCleared() throws {
    let url = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = FileActiveRouteStore(fileURL: url)
    #expect(try store.load() == nil)

    try store.save(sampleRoute())
    let newer = sampleRoute()
    try store.save(newer)
    #expect(try store.load() == newer)

    try store.clear()
    #expect(try store.load() == nil)
    try store.clear()
}

@Test @MainActor func corruptedLocalCopyIsReportedAsError() throws {
    let url = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("no es json".utf8).write(to: url)

    #expect(throws: (any Error).self) { try FileActiveRouteStore(fileURL: url).load() }
}

// MARK: - Backend

private let backendResponse = Data("""
{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","origin":{"name":"Ubicación actual",
"latitude":4.6097,"longitude":-74.0817},"destination":{"name":"Farmacia Central",
"latitude":4.611,"longitude":-74.079},"steps":[],"distance_meters":320.0,
"expected_travel_time_seconds":260.0,"current_step":0,"status":"active",
"started_at":"2026-11-07T15:30:00Z"}
""".utf8)

@Test @MainActor func uploadSendsTheBackendContract() async throws {
    let client = FakeHTTPClient(response: .success(backendResponse))
    let service = RemoteActiveRouteService(client: client, baseURL: URL(string: "http://localhost:8000")!)

    let remoteID = try await service.upload(sampleRoute())

    #expect(remoteID == UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF"))
    let request = try #require(client.requests.first)
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.absoluteString == "http://localhost:8000/places/routes/active")
    // La identidad la añade AuthorizedHTTPClient (Bearer); ya no se envía X-User-Id.
    #expect(request.value(forHTTPHeaderField: "X-User-Id") == nil)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(json.keys) == [
        "origin", "destination", "steps", "distance_meters", "expected_travel_time_seconds",
    ])
    let steps = try #require(json["steps"] as? [[String: Any]])
    #expect(steps.count == 2)
    #expect(Set(steps[0].keys) == ["order", "instruction", "distance_meters", "latitude", "longitude"])
    // Sin punto de maniobra no se envían coordenadas (el backend exige ambas o ninguna).
    #expect(Set(steps[1].keys) == ["order", "instruction", "distance_meters"])
    let destination = try #require(json["destination"] as? [String: Any])
    #expect(destination["name"] as? String == "Farmacia Central")
}

@Test @MainActor func uploadRequiresConfiguration() async {
    let client = FakeHTTPClient(response: .success(backendResponse))
    let service = RemoteActiveRouteService(client: client, baseURL: nil)

    await #expect(throws: RemoteRouteError.notConfigured) {
        try await service.upload(sampleRoute())
    }
    await #expect(throws: RemoteRouteError.notConfigured) {
        try await service.updateDestination(of: sampleRoute(), remoteID: UUID())
    }
    #expect(client.requests.isEmpty)
}

@Test @MainActor func uploadPropagatesBackendErrors() async {
    let client = FakeHTTPClient(response: .failure(HTTPClientError.statusCode(401)))
    let service = RemoteActiveRouteService(client: client, baseURL: URL(string: "http://localhost:8000")!)

    await #expect(throws: (any Error).self) { try await service.upload(sampleRoute()) }
}

@Test @MainActor func destinationChangeSendsTheBackendContract() async throws {
    let client = FakeHTTPClient(response: .success(backendResponse))
    let service = RemoteActiveRouteService(client: client, baseURL: URL(string: "http://localhost:8000")!)
    let remoteID = try #require(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF"))

    try await service.updateDestination(of: sampleRoute(), remoteID: remoteID)

    let request = try #require(client.requests.first)
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.absoluteString
        == "http://localhost:8000/places/routes/6f9619ff-8b86-d011-b42d-00cf4fc964ff/destination")
    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(json.keys) == [
        "origin", "destination", "steps", "distance_meters", "expected_travel_time_seconds",
    ])
}

@Test(arguments: [404, 409])
@MainActor func closedBackendRouteIsReportedAsNoLongerOpen(status: Int) async {
    let client = FakeHTTPClient(response: .failure(HTTPClientError.statusCode(status)))
    let service = RemoteActiveRouteService(client: client, baseURL: URL(string: "http://localhost:8000")!)

    await #expect(throws: ActiveRouteSyncError.routeNoLongerOpen) {
        try await service.updateDestination(of: sampleRoute(), remoteID: UUID())
    }
}

@Test @MainActor func otherDestinationChangeErrorsPropagate() async {
    let client = FakeHTTPClient(response: .failure(HTTPClientError.statusCode(503)))
    let service = RemoteActiveRouteService(client: client, baseURL: URL(string: "http://localhost:8000")!)

    await #expect(throws: HTTPClientError.self) {
        try await service.updateDestination(of: sampleRoute(), remoteID: UUID())
    }
}

// MARK: - Configuración

@Test func configurationReadsInfoPlistValues() {
    let configuration = AppConfiguration(info: ["LumioAPIBaseURL": " http://192.168.1.10:8000 "])

    #expect(configuration.apiBaseURL == URL(string: "http://192.168.1.10:8000"))
}

@Test func missingOrInvalidConfigurationIsNil() {
    #expect(AppConfiguration(info: ["LumioAPIBaseURL": ""]).apiBaseURL == nil)
    #expect(AppConfiguration(info: [:]).apiBaseURL == nil)
}

// MARK: - Copias locales anteriores

@Test func localCopyFromBeforeRouteChangesIsStillReadable() throws {
    // Formato guardado por Crear Ruta antes de añadir `revision` y el cambio pendiente.
    let legacy = Data("""
    {"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","origin":{"name":"Ubicación actual",
    "coordinate":{"latitude":4.6097,"longitude":-74.0817}},"destination":{"name":"Farmacia Central",
    "coordinate":{"latitude":4.611,"longitude":-74.079}},"steps":[{"order":0,
    "instruction":"Gira a la derecha","distanceMeters":200}],"distanceMeters":320,
    "expectedTravelTimeSeconds":260,"createdAt":700000000,"currentStep":0}
    """.utf8)

    let route = try JSONDecoder().decode(ActiveRoute.self, from: legacy)

    #expect(route.revision == 0)
    #expect(route.hasPendingDestinationChange == false)
    #expect(route.remoteID == nil)
    #expect(route.isPendingBackendSync)
    #expect(route.destination.name == "Farmacia Central")
}
