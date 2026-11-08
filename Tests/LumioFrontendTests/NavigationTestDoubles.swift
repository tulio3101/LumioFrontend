import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LumioFrontend

let currentPosition = GeoCoordinate(latitude: 4.6097, longitude: -74.0817)
let pharmacy = RoutePlace(
    name: "Farmacia Central", coordinate: GeoCoordinate(latitude: 4.6110, longitude: -74.0790)
)

/// Forma típica de MapKit: un paso inicial sin instrucción y la llegada con distancia 0.
func sampleCalculatedRoute() -> CalculatedRoute {
    CalculatedRoute(
        distanceMeters: 320,
        expectedTravelTimeSeconds: 260,
        steps: [
            CalculatedRouteStep(instruction: "", distanceMeters: 0, maneuverCoordinate: currentPosition),
            CalculatedRouteStep(
                instruction: "Gira a la derecha en la Calle 19",
                distanceMeters: 200,
                maneuverCoordinate: GeoCoordinate(latitude: 4.6108, longitude: -74.0815)
            ),
            CalculatedRouteStep(
                instruction: "El destino está a la izquierda",
                distanceMeters: 0,
                maneuverCoordinate: nil
            ),
        ]
    )
}

enum StubError: Error { case failed }

@MainActor
final class FakeLocationProvider: CurrentLocationProviding {
    var result: Result<GeoCoordinate, Error> = .success(currentPosition)
    private(set) var calls = 0

    func currentLocation() async throws -> GeoCoordinate {
        calls += 1
        return try result.get()
    }
}

@MainActor
final class FakeGeocoder: DestinationGeocoding {
    var result: Result<RoutePlace, Error> = .success(pharmacy)
    private(set) var queries: [String] = []
    private(set) var origins: [GeoCoordinate] = []

    func place(for query: String, near origin: GeoCoordinate) async throws -> RoutePlace {
        queries.append(query)
        origins.append(origin)
        return try result.get()
    }
}

@MainActor
final class FakeRouteCalculator: WalkingRouteCalculating {
    var result: Result<CalculatedRoute, Error> = .success(sampleCalculatedRoute())
    private(set) var origins: [RoutePlace] = []
    private(set) var destinations: [RoutePlace] = []

    func walkingRoute(from origin: RoutePlace, to destination: RoutePlace) async throws
        -> CalculatedRoute {
        origins.append(origin)
        destinations.append(destination)
        return try result.get()
    }
}

@MainActor
final class InMemoryRouteStore: ActiveRouteStoring {
    var route: ActiveRoute?
    var failSave = false

    func load() throws -> ActiveRoute? { route }

    func save(_ route: ActiveRoute) throws {
        if failSave { throw StubError.failed }
        self.route = route
    }

    func clear() throws { route = nil }
}

@MainActor
final class FakeRouteSync: ActiveRouteSyncing {
    var result: Result<UUID, Error> = .success(UUID())
    private(set) var uploads: [ActiveRoute] = []

    func upload(_ route: ActiveRoute) async throws -> UUID {
        uploads.append(route)
        return try result.get()
    }
}

@MainActor
final class SpyArbiter: AudioArbitrating {
    private(set) var received: [AudioMessage] = []
    private(set) var contexts: [AudioDecisionContext] = []

    func receive(_ message: AudioMessage) { received.append(message) }
    func processNext() {}
    func playbackFinished(token: PlaybackToken) {}
    func discardIrrelevant() {}
    func resetSession() {}
    func updateContext(_ context: AudioDecisionContext) { contexts.append(context) }
}

@MainActor
final class SpyHaptics: HapticFeedbackPlaying {
    private(set) var cues: [HapticCue] = []

    func play(_ cue: HapticCue) { cues.append(cue) }
}

final class FakeHTTPClient: HTTPClient {
    var response: Result<Data, Error>
    private(set) var requests: [URLRequest] = []

    init(response: Result<Data, Error>) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        return try response.get()
    }
}

/// Servicio con dobles de prueba; fecha e identificador fijos para comparar resultados.
@MainActor
struct RouteCreationHarness {
    let location = FakeLocationProvider()
    let geocoder = FakeGeocoder()
    let calculator = FakeRouteCalculator()
    let store = InMemoryRouteStore()
    let sync = FakeRouteSync()
    let arbiter = SpyArbiter()
    let haptics = SpyHaptics()
    let now = Date(timeIntervalSince1970: 1_000)
    let service: RouteCreationService

    init(routeIDs: [UUID] = [UUID(), UUID(), UUID()]) {
        var pending = routeIDs
        let fixedNow = now
        service = RouteCreationService(
            location: location,
            geocoder: geocoder,
            calculator: calculator,
            store: store,
            sync: sync,
            arbiter: arbiter,
            haptics: haptics,
            now: { fixedNow },
            makeID: { pending.isEmpty ? UUID() : pending.removeFirst() }
        )
    }
}

func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("lumio-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("active-route.json")
}
