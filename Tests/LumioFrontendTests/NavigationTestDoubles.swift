import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LumioFrontend

let currentPosition = GeoCoordinate(latitude: 4.6097, longitude: -74.0817)
let pharmacy = RoutePlace(
    name: "Farmacia Central", coordinate: GeoCoordinate(latitude: 4.6110, longitude: -74.0790)
)
/// A unos 5 km de la farmacia: un destino claramente distinto.
let park = RoutePlace(
    name: "Parque de los Novios", coordinate: GeoCoordinate(latitude: 4.6580, longitude: -74.0670)
)

/// Ruta corta hacia el parque, para distinguir sus instrucciones de las de la farmacia.
func parkCalculatedRoute() -> CalculatedRoute {
    CalculatedRoute(
        distanceMeters: 80,
        expectedTravelTimeSeconds: 70,
        steps: [
            CalculatedRouteStep(
                instruction: "Camina hacia el sur por la Calle 19",
                distanceMeters: 80,
                maneuverCoordinate: GeoCoordinate(latitude: 4.6102, longitude: -74.0811)
            ),
            CalculatedRouteStep(
                instruction: "El destino está a la derecha", distanceMeters: 0, maneuverCoordinate: nil
            ),
        ]
    )
}

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
    var destinationResult: Result<Void, Error> = .success(())
    private(set) var uploads: [ActiveRoute] = []
    private(set) var destinationUpdates: [(route: ActiveRoute, remoteID: UUID)] = []

    func upload(_ route: ActiveRoute) async throws -> UUID {
        uploads.append(route)
        return try result.get()
    }

    func updateDestination(of route: ActiveRoute, remoteID: UUID) async throws {
        destinationUpdates.append((route, remoteID))
        try destinationResult.get()
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
    private(set) var resets = 0

    func resetSession() { resets += 1 }
    func updateContext(_ context: AudioDecisionContext) { contexts.append(context) }
}

@MainActor
final class SpyHaptics: HapticFeedbackPlaying {
    private(set) var cues: [HapticCue] = []

    func play(_ cue: HapticCue) { cues.append(cue) }
}

final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    var response: Result<Data, Error>
    /// Respuestas en orden para peticiones sucesivas; al agotarse se usa `response`.
    var queued: [Result<Data, Error>] = []
    private(set) var requests: [URLRequest] = []

    init(response: Result<Data, Error>) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        if !queued.isEmpty { return try queued.removeFirst().get() }
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

/// Modificar Ruta con dobles de prueba sobre la misma copia local que Crear Ruta.
@MainActor
struct RouteModificationHarness {
    let location = FakeLocationProvider()
    let geocoder = FakeGeocoder()
    let calculator = FakeRouteCalculator()
    let store = InMemoryRouteStore()
    let sync = FakeRouteSync()
    let arbiter = SpyArbiter()
    let haptics = SpyHaptics()
    let now = Date(timeIntervalSince1970: 2_000)
    let service: RouteModificationService

    init() {
        let fixedNow = now
        geocoder.result = .success(park)
        calculator.result = .success(parkCalculatedRoute())
        service = RouteModificationService(
            location: location,
            geocoder: geocoder,
            calculator: calculator,
            store: store,
            sync: sync,
            arbiter: arbiter,
            haptics: haptics,
            now: { fixedNow }
        )
    }

    /// Ruta activa hacia la farmacia, ya guardada en el backend salvo que se indique.
    @discardableResult
    func storeActiveRoute(remoteID: UUID? = UUID(), currentStep: Int = 1) -> ActiveRoute {
        let route = ActiveRoute(
            id: UUID(),
            remoteID: remoteID,
            origin: RoutePlace(name: "Ubicación actual", coordinate: currentPosition),
            destination: pharmacy,
            steps: NavigationInstructionBuilder().steps(from: sampleCalculatedRoute().steps),
            distanceMeters: 320,
            expectedTravelTimeSeconds: 260,
            createdAt: Date(timeIntervalSince1970: 1_000),
            currentStep: currentStep
        )
        store.route = route
        return route
    }
}

func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("lumio-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("active-route.json")
}

/// Tokens en memoria (Keychain no existe en Linux).
final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?
    var failSave = false

    init(_ tokens: AuthTokens? = nil) {
        self.tokens = tokens
    }

    func load() -> AuthTokens? {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    func save(_ tokens: AuthTokens) throws {
        if failSave { throw StubError.failed }
        lock.lock()
        defer { lock.unlock() }
        self.tokens = tokens
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        tokens = nil
    }
}
