import Foundation
import Testing
@testable import LumioFrontend

// SCRUM-31: Recibir Retroalimentación del Sistema. La matriz evento → prioridad → patrón
// (SCRUM-201), su emisión por el AudioArbiter y el motor háptico (SCRUM-202 a 205) y los
// conflictos de prioridad (SCRUM-206). Usa SpyArbiter, SpyHaptics y FakeAudioPlayer.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func feedbackRoute(steps: [String] = ["Gira a la derecha"]) -> ActiveRoute {
    ActiveRoute(
        id: UUID(),
        remoteID: nil,
        origin: RoutePlace(name: "Ubicación actual", coordinate: GeoCoordinate(latitude: 4.61, longitude: -74.1)),
        destination: RoutePlace(name: "Parque", coordinate: GeoCoordinate(latitude: 4.6, longitude: -74.1)),
        steps: steps.enumerated().map {
            RouteStep(order: $0.offset, instruction: $0.element, distanceMeters: 30, maneuverCoordinate: nil)
        },
        distanceMeters: 30,
        expectedTravelTimeSeconds: 30,
        createdAt: now
    )
}

private func finishResult() -> RouteFinishResult {
    RouteFinishResult(
        finished: FinishedRoute(route: feedbackRoute(), outcome: .completed, finishedAt: now),
        trigger: .arrival
    )
}

private struct Row {
    let event: FeedbackEvent
    let priority: AudioPriority
    let haptic: HapticCue?
}

/// La matriz de `docs/HU-recibir-retroalimentacion-del-sistema.md`. Si cambia un evento, cambia
/// aquí y en el documento.
private func matrix() -> [Row] {
    let route = feedbackRoute()
    let delivery = EmergencyDelivery(contactsTotal: 2, contactsSent: 2, locationIncluded: true)
    return [
        // Navegación (P2)
        Row(event: .routeCreated(route), priority: .routeInformation, haptic: .routeReady),
        Row(event: .routeModified(route), priority: .routeInformation, haptic: .routeReady),
        Row(event: .routeRecalculated(route), priority: .routeInformation, haptic: .routeReady),
        Row(event: .routeFinished(finishResult()), priority: .routeInformation, haptic: .routeFinished),
        Row(event: .arrival(finishResult()), priority: .routeInformation, haptic: .routeFinished),
        Row(event: .routeCreationFailed(.serviceUnavailable), priority: .routeInformation, haptic: .routeFailed),
        Row(event: .routeModificationFailed(.noRouteAvailable, keeping: route), priority: .routeInformation, haptic: .routeFailed),
        Row(event: .rerouteFailed(.serviceUnavailable, destination: "Parque"), priority: .routeInformation, haptic: .routeFailed),
        Row(event: .offline(destination: "Parque"), priority: .routeInformation, haptic: nil),
        Row(event: .backendError, priority: .routeInformation, haptic: .routeFailed),
        // Seguridad (P1 las alertas, P2/P3 las confirmaciones)
        Row(event: .modelUnavailable, priority: .immediateRisk, haptic: nil),
        Row(event: .lowLight, priority: .immediateRisk, haptic: .warning),
        Row(event: .lowLightRecovered, priority: .environmentInformation, haptic: nil),
        Row(event: .thermalPaused, priority: .immediateRisk, haptic: .warning),
        Row(event: .thermalResumed, priority: .routeInformation, haptic: nil),
        Row(event: .detectionRecovered, priority: .routeInformation, haptic: nil),
        Row(event: .reducedMode, priority: SafetyAudio.reducedMode(now: now).priority, haptic: .safetyReady),
        Row(event: .fullMode, priority: SafetyAudio.fullMode(now: now).priority, haptic: .safetyReady),
        Row(event: .permissionsDenied, priority: SafetyAudio.cameraUnavailable().priority, haptic: nil),
        // Emergencia (P1)
        Row(event: .emergencyActivated(seconds: 5), priority: .immediateRisk, haptic: .emergencyActivated),
        Row(event: .emergencyCountdown(2), priority: .immediateRisk, haptic: nil),
        Row(event: .emergencyCancelled, priority: .immediateRisk, haptic: nil),
        Row(event: .emergencySending, priority: .immediateRisk, haptic: nil),
        Row(event: .emergencySent(delivery), priority: .immediateRisk, haptic: .emergencySent),
        Row(event: .emergencyFailed(.offline), priority: .immediateRisk, haptic: .emergencyFailed),
        // Narración y sesión
        Row(event: .narrationUnavailable(.offline), priority: .routeInformation, haptic: .narrationUnavailable),
        Row(event: .narrationAvailable, priority: .routeInformation, haptic: .narrationAvailable),
        Row(event: .sessionClosed, priority: SessionAudio.closed().priority, haptic: nil),
        Row(event: .sessionExpired, priority: SessionAudio.expiredRouteContinues().priority, haptic: nil),
    ]
}

// MARK: SCRUM-201: matriz por evento y prioridad

@Test func everyEventHasTheMatrixPriorityAndHaptic() {
    for row in matrix() {
        let item = FeedbackCatalog.item(for: row.event, now: now)
        #expect(item.message.priority == row.priority, "\(row.event)")
        #expect(item.haptic == row.haptic, "\(row.event)")
        #expect(!item.message.text.trimmingCharacters(in: .whitespaces).isEmpty, "\(row.event)")
    }
}

@Test func safetyAndEmergencyAlertsArePriorityOne() {
    let critical: [FeedbackEvent] = [
        .modelUnavailable, .lowLight, .thermalPaused,
        .emergencyActivated(seconds: 5), .emergencySending, .emergencyFailed(.server),
    ]
    for event in critical {
        #expect(FeedbackCatalog.item(for: event, now: now).message.priority == .immediateRisk, "\(event)")
    }
}

@Test func narrationAndInformationNeverOutrankNavigation() {
    // Prioridad 3: lo informativo nunca interrumpe una indicación.
    #expect(FeedbackCatalog.item(for: .lowLightRecovered, now: now).message.priority == .environmentInformation)
    #expect(NarrationAudio.message(text: "Hay una puerta.", capturedAt: now, captureSequence: 1).priority
        == .environmentInformation)
}

@Test func priorityOneAlertsUseVibrationsTheUserCannotTurnOff() {
    // Una alerta crítica no puede quedar muda en la mano: o su patrón es de los que siempre
    // vibran, o no trae patrón y vibra `criticalAlert` cuando el árbitro la empieza a sonar.
    for row in matrix() where row.priority == .immediateRisk {
        if let cue = row.haptic {
            #expect(HapticCue.alwaysOn.contains(cue), "\(row.event)")
        }
    }
}

// MARK: SCRUM-202/203: errores y acciones producen retroalimentación

@Test func everyRouteErrorIsSpokenAndVibrates() {
    for failure in RouteCreationError.allCases {
        for event: FeedbackEvent in [
            .routeCreationFailed(failure),
            .routeModificationFailed(failure, keeping: nil),
            .rerouteFailed(failure, destination: "Parque"),
        ] {
            let item = FeedbackCatalog.item(for: event, now: now)
            #expect(!item.message.text.isEmpty, "\(event)")
            #expect(item.haptic == .routeFailed, "\(event)")
        }
    }
}

@Test func everyEmergencyFailureIsSpokenWithTheEmergencyLine() {
    let failures: [EmergencyFailure] = [.offline, .sessionExpired, .noContacts, .deliveryFailed, .server]
    for failure in failures {
        let item = FeedbackCatalog.item(for: .emergencyFailed(failure), now: now)
        #expect(item.message.text.contains(EmergencyAnnouncements.emergencyLine), "\(failure)")
        #expect(item.message.contextID == EmergencyService.contextID)
    }
}

// MARK: SCRUM-204: un solo camino, el árbitro y el motor háptico

@Test @MainActor func emitSendsTheMessageToTheArbiterAndTheCueToTheHapticEngine() {
    let arbiter = SpyArbiter()
    let haptics = SpyHaptics()

    FeedbackCatalog.emit(.lowLight, audio: arbiter, haptics: haptics, now: now)

    #expect(arbiter.received.map(\.text) == [FeedbackCatalog.item(for: .lowLight, now: now).message.text])
    #expect(haptics.cues == [.warning])
}

@Test @MainActor func emitWithoutACueOnlySpeaks() {
    let arbiter = SpyArbiter()
    let haptics = SpyHaptics()

    FeedbackCatalog.emit(.lowLightRecovered, audio: arbiter, haptics: haptics, now: now)

    #expect(arbiter.received.count == 1)
    #expect(haptics.cues.isEmpty)
}

@Test @MainActor func feedbackDoesNotDependOnEitherChannel() {
    // Sin árbitro (por ejemplo, en una vista previa) la vibración sigue; sin motor háptico, el
    // audio sigue. Ninguno bloquea al otro ni al módulo que emite.
    let haptics = SpyHaptics()
    FeedbackCatalog.emit(.emergencyActivated(seconds: 5), audio: nil, haptics: haptics, now: now)
    #expect(haptics.cues == [.emergencyActivated])

    let arbiter = SpyArbiter()
    FeedbackCatalog.emit(.emergencyActivated(seconds: 5), audio: arbiter, haptics: nil, now: now)
    #expect(arbiter.received.count == 1)
}

/// Deja correr las tareas @MainActor que emiten el aviso (LowLightDetector usa Task { @MainActor }).
private func drainMainActor() async {
    try? await Task.sleep(nanoseconds: 20_000_000)
}

@Test @MainActor func lowLightAlertGoesThroughTheHapticEngine() async {
    let arbiter = SpyArbiter()
    let haptics = SpyHaptics()
    let detector = LowLightDetector(audioArbiter: arbiter, haptics: haptics, alertThreshold: 100, hysteresisMargin: 40)

    detector.analyze(ambientIntensity: 50)
    await drainMainActor()
    detector.analyze(ambientIntensity: 60)
    await drainMainActor()

    #expect(arbiter.received.map(\.deduplicationKey) == ["low-light-alert"])
    #expect(arbiter.received.first?.priority == .immediateRisk)
    #expect(haptics.cues == [.warning])

    detector.analyze(ambientIntensity: 200)
    await drainMainActor()

    #expect(arbiter.received.map(\.deduplicationKey) == ["low-light-alert", "low-light-recovered"])
    #expect(arbiter.received.last?.priority == .environmentInformation)
    #expect(haptics.cues == [.warning])
}

// MARK: SCRUM-205: los flujos principales emiten lo que dice la matriz

@Test @MainActor func emergencyFlowSpeaksAndVibratesFromTheCatalog() {
    let arbiter = SpyArbiter()
    let haptics = SpyHaptics()
    let service = EmergencyService(
        remote: NoEmergencyRemote(),
        locator: NoEmergencyLocator(),
        connectivity: AlwaysConnected(),
        contactCount: { 1 },
        tokens: nil,
        arbiter: arbiter,
        haptics: haptics,
        sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000_000_000) },
        now: { now }
    )

    service.activate()
    service.cancel()

    #expect(arbiter.received.map(\.text) == [
        FeedbackCatalog.item(for: .emergencyActivated(seconds: EmergencyService.countdownSeconds), now: now).message.text,
        FeedbackCatalog.item(for: .emergencyCancelled, now: now).message.text,
    ])
    #expect(arbiter.received.allSatisfy { $0.priority == .immediateRisk })
    #expect(haptics.cues == [.emergencyActivated])
    // Cada aviso reemplaza al anterior del mismo flujo.
    #expect(arbiter.cancelledContexts == [[EmergencyService.contextID], [EmergencyService.contextID]])
}

// MARK: SCRUM-206: conflictos de prioridad en el árbitro real

@Test @MainActor func aCriticalAlertInterruptsNavigationFeedbackWhichThenPlays() {
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player, now: { now })

    FeedbackCatalog.emit(.routeCreated(feedbackRoute()), audio: arbiter, now: now)
    let ready = arbiter.currentMessage
    #expect(ready?.priority == .routeInformation)

    FeedbackCatalog.emit(.lowLight, audio: arbiter, now: now)

    #expect(arbiter.currentMessage?.priority == .immediateRisk)
    #expect(player.stops == 1)
    player.finish()
    #expect(arbiter.currentMessage?.text == ready?.text)
}

@Test @MainActor func navigationFeedbackWaitsBehindACriticalAlert() {
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player, now: { now })

    FeedbackCatalog.emit(.thermalPaused, audio: arbiter, now: now)
    FeedbackCatalog.emit(.narrationUnavailable(.offline), audio: arbiter, now: now)

    // La P2 no corta la P1: espera su turno.
    #expect(arbiter.currentMessage?.priority == .immediateRisk)
    #expect(player.stops == 0)
    player.finish()
    #expect(arbiter.currentMessage?.text == EnvironmentNarrationMessages.outage(.offline))
}

@Test @MainActor func informationNeverInterruptsAnInstruction() {
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player, now: { now })

    FeedbackCatalog.emit(.routeRecalculated(feedbackRoute()), audio: arbiter, now: now)
    FeedbackCatalog.emit(.lowLightRecovered, audio: arbiter, now: now)

    #expect(arbiter.currentMessage?.priority == .routeInformation)
    #expect(player.stops == 0)
}

@Test @MainActor func aRepeatedAlertIsNotQueuedTwice() {
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player, now: { now })

    FeedbackCatalog.emit(.routeCreated(feedbackRoute()), audio: arbiter, now: now)
    FeedbackCatalog.emit(.offline(destination: "Parque"), audio: arbiter, now: now)
    FeedbackCatalog.emit(.offline(destination: "Parque"), audio: arbiter, now: now)

    player.finish()
    #expect(arbiter.currentMessage?.deduplicationKey == "offline")
    player.finish()
    #expect(arbiter.currentMessage == nil)
}

// MARK: Sin un gestor de vibración paralelo

/// Solo el motor háptico vibra (el audio ya lo vigila `onlyTheArbiterPlayerUsesPlaybackAPIs`,
/// SCRUM-42). Un generador de vibración en otro archivo se saltaría las preferencias del
/// usuario y rompería el criterio de la HU.
@Test func noHapticOutputOutsideTheHapticEngine() throws {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LumioFrontend")
    let forbidden = [
        "UINotificationFeedbackGenerator", "UIImpactFeedbackGenerator", "UISelectionFeedbackGenerator",
        "CHHapticEngine", "CHHapticPattern", ".sensoryFeedback(", "kSystemSoundID_Vibrate",
    ]
    let allowed: Set<String> = ["UIKitHapticFeedback.swift"]  // El motor háptico.
    guard let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
        Issue.record("No se encontró \(sources.path)")
        return
    }
    var scanned = 0
    var offenders: [String] = []
    for case let file as URL in files where file.pathExtension == "swift" {
        scanned += 1
        guard !allowed.contains(file.lastPathComponent) else { continue }
        let code = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        for (number, line) in code.enumerated() where forbidden.contains(where: { line.contains($0) }) {
            offenders.append("\(file.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
    }
    #expect(scanned > 50)
    #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
}

// MARK: Dobles de emergencia

private struct NoEmergencyRemote: EmergencyRemoting {
    func send(_ alert: EmergencyAlert) async throws -> EmergencyDelivery {
        EmergencyDelivery(contactsTotal: 1, contactsSent: 1, locationIncluded: false)
    }
}

private struct NoEmergencyLocator: EmergencyLocating {
    func currentLocation() async -> EmergencyLocation? { nil }
}

@MainActor
private final class AlwaysConnected: ConnectivityObserving {
    var isConnected = true
    func start(onReconnect: @escaping @MainActor () -> Void) {}
}
