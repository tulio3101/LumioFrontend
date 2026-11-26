import Foundation
import Testing
@testable import LumioFrontend

/// Guiar Giros durante el Trayecto (SCRUM-312): lado y geometría de cada maniobra, cuándo
/// anunciarla, anuncios por el AudioArbiter con su vibración, avance del paso en la copia
/// local, llegada y avisos de GPS y red.

// MARK: - Ruta de prueba

/// Origen → 200 m al norte (gira a la izquierda) → 150 m al oeste (gira a la derecha) →
/// 100 m al norte hasta el destino.
private let turnOrigin = GeoCoordinate(latitude: 4.6000, longitude: -74.0800)
private let metersPerDegreeLatitude = 6_371_000 * Double.pi / 180
private let metersPerDegreeLongitude = metersPerDegreeLatitude * cos(4.6 * Double.pi / 180)

private func north(_ meters: Double, of coordinate: GeoCoordinate) -> GeoCoordinate {
    GeoCoordinate(latitude: coordinate.latitude + meters / metersPerDegreeLatitude, longitude: coordinate.longitude)
}

private func west(_ meters: Double, of coordinate: GeoCoordinate) -> GeoCoordinate {
    GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude - meters / metersPerDegreeLongitude)
}

private func east(_ meters: Double, of coordinate: GeoCoordinate) -> GeoCoordinate {
    west(-meters, of: coordinate)
}

private let leftTurnPoint = north(200, of: turnOrigin)
private let rightTurnPoint = west(150, of: leftTurnPoint)
private let library = RoutePlace(name: "Biblioteca Nacional", coordinate: north(100, of: rightTurnPoint))

private func turnRoute(revision: Int = 0) -> ActiveRoute {
    ActiveRoute(
        id: UUID(uuidString: "6F1C2F0E-3B6B-4C51-9E6B-0E5D2B2C1A11")!,
        remoteID: nil,
        origin: RoutePlace(name: "Ubicación actual", coordinate: turnOrigin),
        destination: library,
        steps: [
            RouteStep(order: 0, instruction: "Camina hacia el norte por la Carrera 7", distanceMeters: 200, maneuverCoordinate: turnOrigin),
            RouteStep(order: 1, instruction: "Gira a la izquierda en la Calle 26", distanceMeters: 150, maneuverCoordinate: leftTurnPoint),
            RouteStep(order: 2, instruction: "Gira a la derecha en la Carrera 10", distanceMeters: 100, maneuverCoordinate: rightTurnPoint),
            RouteStep(order: 3, instruction: "El destino está a la derecha", distanceMeters: 0, maneuverCoordinate: nil),
        ],
        distanceMeters: 450,
        expectedTravelTimeSeconds: 400,
        createdAt: Date(timeIntervalSince1970: 1_000),
        revision: revision
    )
}

private func turnFix(_ coordinate: GeoCoordinate, accuracy: Double = 5, speed: Double? = 1) -> LocationFix {
    LocationFix(coordinate: coordinate, horizontalAccuracy: accuracy, speedMetersPerSecond: speed)
}

@MainActor
private final class TurnHarness {
    let store = InMemoryRouteStore()
    let arbiter = SpyArbiter()
    let haptics = SpyHaptics()
    let connectivity = FakeConnectivity()
    var clock = Date(timeIntervalSince1970: 50_000)
    lazy var monitor = TurnGuidanceMonitor(
        store: store, arbiter: arbiter, haptics: haptics, connectivity: connectivity,
        watchdogInterval: nil, now: { [unowned self] in self.clock }
    )

    init(start: Bool = true) {
        store.route = turnRoute()
        if start { monitor.trackingDidStart() }
    }

    var texts: [String] { arbiter.received.map(\.text) }
}

// MARK: - Lado y geometría de la maniobra

@Test func maneuverSideAndGeometryComeFromTheInstruction() {
    #expect(TurnManeuver(instruction: "Gira a la izquierda en la Calle 26") == TurnManeuver(direction: .left, geometry: .sharp))
    #expect(TurnManeuver(instruction: "Gira ligeramente a la derecha") == TurnManeuver(direction: .right, geometry: .wide))
    #expect(TurnManeuver(instruction: "Mantente a la izquierda") == TurnManeuver(direction: .left, geometry: .wide))
    #expect(TurnManeuver(instruction: "GIRA A LA DERECHA") == TurnManeuver(direction: .right, geometry: .sharp))
    #expect(TurnManeuver(instruction: "Turn right onto Main St") == TurnManeuver(direction: .right, geometry: .sharp))
    #expect(TurnManeuver(instruction: "Continúa recto por la Avenida Jiménez").direction == .none)
    // Si nombra los dos lados, manda el primero.
    #expect(TurnManeuver(instruction: "Gira a la izquierda y luego a la derecha").direction == .left)
}

@Test func leftAndRightVibrateWithDistinctPatterns() {
    #expect(TurnDirection.left.hapticCue == .turnLeft)
    #expect(TurnDirection.right.hapticCue == .turnRight)
    #expect(TurnDirection.none.hapticCue == nil)
    let left = HapticPattern.pattern(for: .turnLeft, intensity: .strong)
    let right = HapticPattern.pattern(for: .turnRight, intensity: .strong)
    #expect(left != right)
    #expect(left.pulses.count == 2)
    #expect(right.pulses.count == 3)
    #expect(HapticCue.configurable.contains(.turnLeft))
    #expect(HapticCue.configurable.contains(.turnRight))
}

@Test func turnsNeverFeelLikeASafetyAlert() {
    // Con cualquier intensidad, un giro no puede sentirse como un desnivel u otra alerta.
    for intensity in HapticIntensity.allCases {
        for turn in [HapticCue.turnLeft, .turnRight] {
            let pattern = HapticPattern.pattern(for: turn, intensity: intensity)
            for alert in HapticCue.alwaysOn {
                #expect(pattern != HapticPattern.pattern(for: alert, intensity: intensity), "\(turn) = \(alert)")
            }
        }
    }
}

// MARK: - Cuándo anunciar

@Test func announcementDistanceGrowsWithWalkingSpeed() {
    let policy = TurnGuidancePolicy()
    // A 1 m/s: aviso previo a 30 m y «Ahora» a 8 m (los mínimos).
    #expect(policy.prepareDistance(speed: 1) == 30)
    #expect(policy.imminentDistance(speed: 1) == 8)
    // A 2 m/s: 50 m y 12 m.
    #expect(policy.prepareDistance(speed: 2) == 50)
    #expect(policy.imminentDistance(speed: 2) == 12)
    #expect(policy.stage(distanceMeters: 40, speed: 1) == nil)
    #expect(policy.stage(distanceMeters: 25, speed: 1) == .prepare)
    #expect(policy.stage(distanceMeters: 5, speed: 1) == .now)
    #expect(policy.stage(distanceMeters: 45, speed: 2) == .prepare)
}

@Test func unusableGpsSpeedFallsBackToTypicalWalking() {
    let policy = TurnGuidancePolicy()
    #expect(policy.walkingSpeed(of: turnFix(turnOrigin, speed: nil)) == TurnDeadline.typicalWalkingSpeed)
    #expect(policy.walkingSpeed(of: turnFix(turnOrigin, speed: 0.05)) == TurnDeadline.typicalWalkingSpeed)
    #expect(policy.walkingSpeed(of: turnFix(turnOrigin, speed: 8)) == TurnDeadline.typicalWalkingSpeed)
    #expect(policy.walkingSpeed(of: turnFix(turnOrigin, speed: 1.4)) == 1.4)
}

@Test func spokenTurnDistanceIsRoundedToFiveMeters() {
    #expect(TurnAnnouncements.spokenDistance(23) == "25 metros")
    #expect(TurnAnnouncements.spokenDistance(2) == "5 metros")
    #expect(TurnAnnouncements.spokenDistance(140) == "140 metros")
}

// MARK: - Anuncios de giro

@Test @MainActor func turnIsAnnouncedAheadWithSideDistanceAndVibration() throws {
    let h = TurnHarness()

    h.monitor.receive(turnFix(north(175, of: turnOrigin)))
    h.monitor.receive(turnFix(north(177, of: turnOrigin)))

    #expect(h.texts == ["En 25 metros, gira a la izquierda en la Calle 26."])
    let message = try #require(h.arbiter.received.first)
    #expect(message.priority == .routeInformation)
    // Contexto propio del giro dentro de la revisión: se corta cuando ya toca «Ahora».
    #expect(message.contextID == NavigationInstructionBuilder.contextID(for: turnRoute()) + "-turn-1")
    #expect(message.deduplicationKey == "turn-1-prepare")
    let deadline = try #require(message.turnDeadline)
    #expect(abs(deadline.maneuverAt.timeIntervalSince(h.clock) - 25) < 0.5)
    #expect(deadline.geometry == .sharp)
    #expect(h.haptics.cues == [.turnLeft])
}

@Test @MainActor func turnIsAnnouncedAgainWhenItIsTimeToTurn() throws {
    let h = TurnHarness()

    h.monitor.receive(turnFix(north(175, of: turnOrigin)))
    h.clock = h.clock.addingTimeInterval(20)
    h.monitor.receive(turnFix(north(195, of: turnOrigin)))

    #expect(h.texts == [
        "En 25 metros, gira a la izquierda en la Calle 26.",
        "Ahora, gira a la izquierda en la Calle 26 y continúa 150 metros.",
    ])
    let now = try #require(h.arbiter.received.last)
    #expect(now.contextID == NavigationInstructionBuilder.contextID(for: turnRoute()))
    // El aviso previo, si aún esperaba turno, se corta para no sonar después de «Ahora».
    #expect(h.arbiter.cancelledContexts == [[NavigationInstructionBuilder.contextID(for: turnRoute()) + "-turn-1"]])
    let deadline = try #require(now.turnDeadline)
    #expect(abs(deadline.maneuverAt.timeIntervalSince(h.clock) - 5) < 0.5)
    // Si no sonó poco después del giro, ya no sirve.
    let expiresAt = try #require(now.expiresAt)
    #expect(abs(expiresAt.timeIntervalSince(deadline.maneuverAt) - TurnGuidancePolicy().announcementGraceSeconds) < 0.001)
    #expect(h.haptics.cues == [.turnLeft, .turnLeft])
}

@Test @MainActor func aTurnReachedDirectlySkipsTheEarlyNotice() {
    let h = TurnHarness()

    h.monitor.receive(turnFix(north(195, of: turnOrigin)))
    h.monitor.receive(turnFix(north(196, of: turnOrigin)))

    #expect(h.texts == ["Ahora, gira a la izquierda en la Calle 26 y continúa 150 metros."])
}

@Test @MainActor func rightTurnVibratesDifferentlyAndAdvancesTheStoredStep() {
    let h = TurnHarness()

    h.monitor.receive(turnFix(west(145, of: leftTurnPoint)))

    #expect(h.texts == ["Ahora, gira a la derecha en la Carrera 10 y continúa 100 metros."])
    #expect(h.haptics.cues == [.turnRight])
    // La copia local queda en el giro que viene: Repetir y Consultar Ruta lo usan.
    #expect(h.store.route?.currentStep == 2)
}

@Test @MainActor func storedStepNeverGoesBack() {
    let h = TurnHarness()
    h.store.route?.currentStep = 2

    h.monitor.receive(turnFix(north(100, of: turnOrigin)))

    #expect(h.store.route?.currentStep == 2)
}

@Test @MainActor func firstInstructionIsNotRepeatedAtTheStart() {
    let h = TurnHarness()

    // Detrás del origen: la maniobra que viene es la inicial, ya dicha con «Ruta lista».
    h.monitor.receive(turnFix(north(-5, of: turnOrigin)))

    #expect(h.arbiter.received.isEmpty)
    #expect(h.haptics.cues.isEmpty)
    #expect(h.store.route?.currentStep == 0)
}

@Test @MainActor func arrivalIsAnnouncedOnceBeforeReachingTheDestination() {
    let h = TurnHarness()

    h.monitor.receive(turnFix(north(72, of: rightTurnPoint)))
    h.monitor.receive(turnFix(north(73, of: rightTurnPoint)))

    #expect(h.texts == ["En 30 metros, llegas a Biblioteca Nacional. El destino está a la derecha."])
    #expect(h.haptics.cues.isEmpty)
    #expect(h.arbiter.received.first?.priority == .routeInformation)
}

@Test @MainActor func noTurnsAreAnnouncedOffTheRoute() {
    let h = TurnHarness()

    h.monitor.receive(turnFix(east(60, of: north(180, of: turnOrigin))))

    #expect(h.arbiter.received.isEmpty)
    #expect(h.store.route?.currentStep == 0)
}

@Test @MainActor func impreciseFixesDoNotAnnounceTurns() {
    let h = TurnHarness()

    h.monitor.receive(turnFix(north(195, of: turnOrigin), accuracy: 60))

    #expect(h.arbiter.received.isEmpty)
    #expect(h.store.route?.currentStep == 0)
}

@Test @MainActor func aNewRevisionAnnouncesItsTurnsAgain() {
    let h = TurnHarness()
    h.monitor.receive(turnFix(north(175, of: turnOrigin)))

    // Cambio de destino o recálculo: otra revisión, `currentStep` vuelve a 0.
    h.store.route = turnRoute(revision: 1)
    h.monitor.receive(turnFix(north(176, of: turnOrigin)))

    #expect(h.arbiter.received.count == 2)
    #expect(h.arbiter.received.last?.contextID == NavigationInstructionBuilder.contextID(for: turnRoute(revision: 1)) + "-turn-1")
    // El aviso previo del recorrido anterior ya no debe sonar.
    #expect(h.arbiter.cancelledContexts == [[NavigationInstructionBuilder.contextID(for: turnRoute()) + "-turn-1"]])
}

@Test @MainActor func guidanceUsesOnlyTheLocalCopyAndStopsWithoutARoute() {
    let h = TurnHarness()
    h.store.route = nil

    h.monitor.receive(turnFix(north(195, of: turnOrigin)))

    #expect(h.arbiter.received.isEmpty)
}

// MARK: - Espera a la locución en curso salvo urgencia (SCRUM-309)

@Test @MainActor func turnWaitsForNarrationUnlessItCannotWait() throws {
    var clock = Date(timeIntervalSince1970: 50_000)
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player, now: { clock }, schedule: { _, _ in })
    let store = InMemoryRouteStore()
    store.route = turnRoute()
    let monitor = TurnGuidanceMonitor(
        store: store, arbiter: arbiter, haptics: SpyHaptics(), connectivity: FakeConnectivity(),
        watchdogInterval: nil, now: { clock }
    )
    monitor.trackingDidStart()
    // Narración (P3) de unos 10 s sonando.
    let narration = NarrationAudio.message(
        text: String(repeating: "a", count: 13 * 10), capturedAt: clock, captureSequence: 1, lifetime: 60
    )
    arbiter.receive(narration)

    // A 25 m el giro puede esperar a que termine: la narración sigue.
    monitor.receive(turnFix(north(175, of: turnOrigin)))
    #expect(arbiter.currentMessage?.id == narration.id)
    #expect(arbiter.pendingMessages.map(\.deduplicationKey) == ["turn-1-prepare"])

    // 3 s después el giro está a 5 m y a la narración le quedan unos 7 s: «Ahora» la corta.
    // El aviso previo que esperaba se descarta y no suena después.
    clock = clock.addingTimeInterval(3)
    monitor.receive(turnFix(north(195, of: turnOrigin)))
    #expect(arbiter.currentMessage?.deduplicationKey == "turn-1-now")
    #expect(arbiter.pendingMessages.isEmpty)
}

// MARK: - GPS y red

@Test @MainActor func weakGpsIsAnnouncedAndItsRecoveryToo() {
    let h = TurnHarness()
    let imprecise = turnFix(north(100, of: turnOrigin), accuracy: 60)

    h.monitor.receive(imprecise)
    h.monitor.receive(imprecise)
    #expect(h.arbiter.received.isEmpty)
    h.monitor.receive(imprecise)
    h.monitor.receive(imprecise)
    h.monitor.receive(turnFix(north(100, of: turnOrigin)))
    h.monitor.receive(turnFix(north(101, of: turnOrigin)))

    #expect(h.texts == [TurnAnnouncements.gpsWeak, TurnAnnouncements.gpsRecovered])
    #expect(TurnAnnouncements.gpsWeak.contains("detección de obstáculos sigue activa"))
    #expect(h.arbiter.received.allSatisfy { $0.priority == .routeInformation })
}

@Test @MainActor func noFixesForAWhileMeansWeakGps() {
    let h = TurnHarness()

    h.clock = h.clock.addingTimeInterval(10)
    h.monitor.checkSignal()
    #expect(h.arbiter.received.isEmpty)
    h.clock = h.clock.addingTimeInterval(6)
    h.monitor.checkSignal()
    h.monitor.checkSignal()

    #expect(h.texts == [TurnAnnouncements.gpsWeak])
}

@Test @MainActor func losingAndRecoveringTheNetworkIsAnnounced() {
    let h = TurnHarness()
    h.connectivity.isConnected = false

    h.monitor.receive(turnFix(north(100, of: turnOrigin)))
    h.monitor.receive(turnFix(north(101, of: turnOrigin)))
    #expect(h.texts == [TurnAnnouncements.offline])

    // Sin red la guía sigue: los giros se anuncian con la copia local.
    h.monitor.receive(turnFix(north(175, of: turnOrigin)))
    #expect(h.texts.last == "En 25 metros, gira a la izquierda en la Calle 26.")

    h.connectivity.isConnected = true
    for handler in h.connectivity.handlers { handler() }
    #expect(h.texts.last == TurnAnnouncements.online)
    #expect(h.texts.count == 3)
}

// MARK: - Fuente de GPS compartida

@Test @MainActor func guidanceFollowsTheSharedGpsWhileTheRouteIsTracked() {
    let base = FakeLocationTracker()
    let shared = SharedLocationTracker(base: base)
    let arrival = shared.makeClient()
    let h = TurnHarness(start: false)
    shared.addObserver(h.monitor)

    base.onFix?(turnFix(north(175, of: turnOrigin)))
    #expect(h.arbiter.received.isEmpty)
    #expect(!h.monitor.isGuiding)

    arrival.start()
    #expect(base.starts == 1)
    #expect(h.monitor.isGuiding)
    base.onFix?(turnFix(north(175, of: turnOrigin)))
    #expect(h.arbiter.received.count == 1)

    arrival.stop()
    #expect(!h.monitor.isGuiding)
    base.onFix?(turnFix(north(195, of: turnOrigin)))
    #expect(h.arbiter.received.count == 1)
}
