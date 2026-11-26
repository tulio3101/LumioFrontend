import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

// Configurar Retroalimentación Háptica: activar o desactivar, elegir eventos e intensidad,
// un patrón por evento, leer y guardar en el teléfono, y alertas críticas que siempre vibran.
// Sin motor real: reproductor y almacenamiento falsos.

@MainActor
private final class RecordingHapticPlayer: HapticPatternPlaying {
    var supportsHaptics = true
    private(set) var played: [HapticPattern] = []

    func play(_ pattern: HapticPattern) { played.append(pattern) }
}

private final class MemoryHapticStore: HapticPreferencesStoring {
    var saved: HapticPreferences?
    var failLoad = false
    var failSave = false
    private(set) var saves = 0

    init(_ saved: HapticPreferences? = nil) { self.saved = saved }

    func load() throws -> HapticPreferences? {
        if failLoad { throw StubError.failed }
        return saved
    }

    func save(_ preferences: HapticPreferences) throws {
        saves += 1
        if failSave { throw StubError.failed }
        saved = preferences
    }

    func clear() throws { saved = nil }
}

@MainActor
private struct HapticHarness {
    let store: MemoryHapticStore
    let player = RecordingHapticPlayer()
    let arbiter = SpyArbiter()
    let service: HapticPreferencesService

    init(stored: HapticPreferences? = nil, failLoad: Bool = false) {
        let memory = MemoryHapticStore(stored)
        memory.failLoad = failLoad
        store = memory
        service = HapticPreferencesService(store: memory, player: player, arbiter: arbiter)
    }
}

private func pattern(_ cue: HapticCue, _ intensity: HapticIntensity = .medium) -> HapticPattern {
    HapticPattern.pattern(for: cue, intensity: intensity)
}

// MARK: - Leer del teléfono

@Test @MainActor func storedPreferencesAreUsedWhenTheAppOpens() {
    let stored = HapticPreferences(isEnabled: true, intensity: .strong, disabledCues: [.routeFinished])
    let harness = HapticHarness(stored: stored)

    #expect(harness.service.preferences == stored)
    #expect(!harness.service.storedUnreadable)
    #expect(harness.store.saves == 0)
}

@Test @MainActor func withoutStoredPreferencesEverythingVibrates() {
    let harness = HapticHarness()

    #expect(harness.service.preferences == .standard)
    for cue in HapticCue.allCases { #expect(harness.service.preferences.plays(cue)) }
}

@Test @MainActor func unreadableFileFallsBackToStandard() {
    let harness = HapticHarness(failLoad: true)

    #expect(harness.service.preferences == .standard)
    #expect(harness.service.storedUnreadable)
}

// MARK: - Cada evento con su patrón

@Test @MainActor func eachEventPlaysItsPattern() {
    let harness = HapticHarness()

    for cue in HapticCue.configurable { harness.service.play(cue) }

    #expect(harness.player.played == HapticCue.configurable.map { pattern($0) })
}

@Test func everyEventHasADistinctPattern() {
    let patterns = HapticCue.allCases.map { pattern($0) }
    for (index, current) in patterns.enumerated() {
        #expect(!patterns[(index + 1)...].contains(current))
        #expect(!current.pulses.isEmpty)
    }
}

@Test func intensityScalesRouteEventsButNotCriticalAlerts() {
    let soft = pattern(.routeReady, .soft).pulses.map(\.strength)
    let strong = pattern(.routeReady, .strong).pulses.map(\.strength)
    #expect(soft.allSatisfy { $0 < 0.5 })
    #expect(strong.allSatisfy { $0 == 1 })
    #expect(pattern(.criticalAlert, .soft) == pattern(.criticalAlert, .strong))
    #expect(pattern(.criticalAlert, .soft).pulses.allSatisfy { $0.strength == 1 })
}

// MARK: - Activar, desactivar y elegir eventos

@Test @MainActor func turningVibrationOffSilencesRouteEvents() {
    let harness = HapticHarness()
    var off = HapticPreferences.standard
    off.isEnabled = false
    #expect(harness.service.update(off) == .saved)

    for cue in HapticCue.configurable { harness.service.play(cue) }

    #expect(harness.player.played.isEmpty)
}

@Test @MainActor func aDisabledEventIsSilentAndTheOthersStillVibrate() {
    let harness = HapticHarness()
    #expect(harness.service.update(HapticPreferences(isEnabled: true, intensity: .medium, disabledCues: [.routeReady])) == .saved)

    harness.service.play(.routeReady)
    harness.service.play(.routeFailed)

    #expect(harness.player.played == [pattern(.routeFailed)])
}

@Test @MainActor func chosenIntensityIsUsed() {
    let harness = HapticHarness()
    #expect(harness.service.update(HapticPreferences(isEnabled: true, intensity: .soft, disabledCues: [])) == .saved)

    harness.service.play(.routeFinished)

    #expect(harness.player.played == [pattern(.routeFinished, .soft)])
}

@Test @MainActor func previewVibratesEvenWhenTheEventIsOff() {
    let harness = HapticHarness(stored: HapticPreferences(isEnabled: false, intensity: .strong, disabledCues: []))

    harness.service.preview(.routeReady)

    #expect(harness.player.played == [pattern(.routeReady, .strong)])
}

@Test @MainActor func sameHapticPreferencesDoNothing() {
    let harness = HapticHarness()

    #expect(harness.service.update(.standard) == .unchanged)
    #expect(harness.store.saves == 0)
}

@Test @MainActor func failedSaveStillAppliesAndSaysItWillNotLast() {
    let harness = HapticHarness()
    harness.store.failSave = true
    var off = HapticPreferences.standard
    off.isEnabled = false

    #expect(harness.service.update(off) == .appliedNotSaved)
    harness.service.play(.routeReady)

    #expect(harness.player.played.isEmpty)
    #expect(harness.arbiter.received.map(\.text) == [HapticPreferencesAnnouncements.notSaved])
    #expect(harness.arbiter.received.first?.priority == .routeInformation)
}

// MARK: - Alertas críticas

@Test @MainActor func criticalAlertsVibrateEvenWithVibrationOff() {
    let harness = HapticHarness(stored: HapticPreferences(isEnabled: false, intensity: .soft, disabledCues: Set(HapticCue.configurable)))

    harness.service.play(.criticalAlert)

    #expect(harness.player.played == [pattern(.criticalAlert)])
}

@Test @MainActor func aCriticalAlertThatStartsPlayingVibratesWithTheArbiter() {
    let harness = HapticHarness(stored: HapticPreferences(isEnabled: false, intensity: .soft, disabledCues: []))
    let speaker = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: speaker)
    arbiter.onMessageChanged = { harness.service.audioMessageChanged($0) }

    arbiter.receive(AudioMessage(text: "Gira a la derecha", priority: .routeInformation))
    arbiter.receive(AudioMessage(text: "Obstáculo al frente", priority: .immediateRisk))

    // Solo la P1 vibra, una vez, al empezar a sonar.
    #expect(harness.player.played == [pattern(.criticalAlert)])
}

@Test @MainActor func emergencyEventsAlwaysVibrateAtFullStrength() {
    let harness = HapticHarness(stored: HapticPreferences(isEnabled: false, intensity: .soft, disabledCues: []))

    harness.service.play(.emergencyActivated)
    harness.service.play(.emergencySent)
    harness.service.play(.emergencyFailed)

    #expect(harness.player.played == [pattern(.emergencyActivated), pattern(.emergencySent), pattern(.emergencyFailed)])
    #expect(harness.player.played.allSatisfy { $0.pulses.allSatisfy { $0.strength == 1 } })
    // SCRUM-33: los desniveles/obstáculos (danger, warning) también vibran siempre (seguridad).
    #expect(HapticCue.alwaysOn == [.danger, .warning, .emergencyActivated, .emergencySent, .emergencyFailed, .criticalAlert, .safetyReady])
    #expect(HapticCue.configurable == [.routeReady, .routeFailed, .routeFinished, .turnLeft, .turnRight])
}

// MARK: - Se conservan al cerrar y abrir la app

@Test @MainActor func hapticPreferencesSurviveClosingAndReopeningTheApp() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumio-haptics-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileHapticPreferencesStore(fileURL: directory.appendingPathComponent("haptic-preferences.json"))
    let chosen = HapticPreferences(isEnabled: true, intensity: .strong, disabledCues: [.routeFailed])

    let first = HapticPreferencesService(store: store, player: nil, arbiter: nil)
    #expect(first.update(chosen) == .saved)

    let reopened = HapticPreferencesService(store: store, player: nil, arbiter: nil)
    #expect(reopened.preferences == chosen)
    #expect(try store.load() == chosen)
    try store.clear()
    #expect(try store.load() == nil)
}

// MARK: - Textos

@Test func summaryDescribesTheCurrentPreferences() {
    #expect(HapticPreferencesAnnouncements.summary(.standard)
        == "Vibración activada. Intensidad media. Todos los eventos vibran.")
    #expect(HapticPreferencesAnnouncements.summary(HapticPreferences(isEnabled: true, intensity: .soft, disabledCues: [.routeFailed]))
        == "Vibración activada. Intensidad suave. Sin vibración: No se pudo calcular la ruta.")
    #expect(HapticPreferencesAnnouncements.summary(HapticPreferences(isEnabled: false, intensity: .soft, disabledCues: []))
        .hasPrefix("Vibración desactivada."))
    #expect(!HapticCue.configurable.contains(.criticalAlert))
}

// MARK: - Eliminar Cuenta

@Test @MainActor func deletingTheAccountForgetsTheHapticPreferences() async {
    let harness = HapticHarness(stored: HapticPreferences(isEnabled: false, intensity: .soft, disabledCues: []))
    let deletion = AccountDeletionService(
        remote: FakeAccountRemover(),
        tokens: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")),
        routes: InMemoryRouteStore(),
        hapticPreferences: harness.service,
        arbiter: SpyArbiter()
    )

    let outcome = await deletion.deleteAccount()

    #expect(outcome == .deleted)
    #expect(harness.store.saved == nil)
    #expect(harness.service.preferences == .standard)
}
