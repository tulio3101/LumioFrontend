import Foundation
import Testing
@testable import LumioFrontend

// SCRUM-32: Configurar Preferencias de Accesibilidad.

private final class MemoryStore: AccessibilityPreferencesStoring {
    var stored: AccessibilityPreferences?
    var failLoad = false
    var failSave = false
    private(set) var cleared = false
    init(_ stored: AccessibilityPreferences? = nil) { self.stored = stored }
    func load() throws -> AccessibilityPreferences? {
        if failLoad { throw CocoaError(.fileReadCorruptFile) }
        return stored
    }
    func save(_ preferences: AccessibilityPreferences) throws {
        if failSave { throw CocoaError(.fileWriteNoPermission) }
        stored = preferences
    }
    func clear() throws {
        cleared = true
        stored = nil
    }
}

private let custom = AccessibilityPreferences(
    autoNarration: false, announceStatusOnLaunch: false, announcementDetail: .brief
)

// MARK: Consultar y modificar

@Test @MainActor func defaultsAreUsedUntilTheUserChangesThem() {
    let service = AccessibilityPreferencesService(store: MemoryStore(), arbiter: nil)
    #expect(service.preferences == .standard)
    #expect(service.preferences.autoNarration)
    #expect(service.preferences.announceStatusOnLaunch)
    #expect(service.preferences.announcementDetail == .detailed)
}

@Test @MainActor func changesAreAppliedAndStored() {
    let store = MemoryStore()
    let service = AccessibilityPreferencesService(store: store, arbiter: nil)
    #expect(service.update(custom) == .saved)
    #expect(service.preferences == custom)
    #expect(store.stored == custom)
    #expect(service.update(custom) == .unchanged)
}

@Test @MainActor func failingToSaveKeepsTheChangeAndSaysSo() {
    let store = MemoryStore()
    store.failSave = true
    let arbiter = SpyArbiter()
    let service = AccessibilityPreferencesService(store: store, arbiter: arbiter)
    #expect(service.update(custom) == .appliedNotSaved)
    #expect(service.preferences == custom)
    #expect(arbiter.received.last?.text == AccessibilityPreferencesAnnouncements.notSaved)
}

@Test @MainActor func anUnreadableFileFallsBackToDefaults() {
    let store = MemoryStore(custom)
    store.failLoad = true
    let service = AccessibilityPreferencesService(store: store, arbiter: nil)
    #expect(service.preferences == .standard)
    #expect(service.storedUnreadable)
}

@Test @MainActor func resetGoesBackToDefaults() {
    let store = MemoryStore(custom)
    let service = AccessibilityPreferencesService(store: store, arbiter: nil)
    service.resetToStandard()
    #expect(service.preferences == .standard)
    #expect(store.cleared)
}

// MARK: Validación y persistencia

@Test func missingOrUnknownValuesTakeTheDefault() throws {
    let old = try JSONDecoder().decode(AccessibilityPreferences.self, from: Data(#"{"autoNarration":false}"#.utf8))
    #expect(old == AccessibilityPreferences(autoNarration: false, announceStatusOnLaunch: true, announcementDetail: .detailed))
    let future = try JSONDecoder().decode(
        AccessibilityPreferences.self,
        from: Data(#"{"autoNarration":true,"announceStatusOnLaunch":"sí","announcementDetail":"verbose"}"#.utf8)
    )
    #expect(future == .standard)
}

@Test @MainActor func preferencesSurviveClosingTheApp() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("accessibility-preferences.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let first = AccessibilityPreferencesService(store: FileAccessibilityPreferencesStore(fileURL: url), arbiter: nil)
    first.update(custom)
    let reopened = AccessibilityPreferencesService(store: FileAccessibilityPreferencesStore(fileURL: url), arbiter: nil)
    #expect(reopened.preferences == custom)
}

// MARK: Se aplican a los módulos

private struct Session: SessionRestoring {
    func hasActiveSession() -> Bool { true }
}

private struct Model: SafetyModelChecking {
    func isModelAvailable() -> Bool { true }
}

@MainActor
private func home(_ preferences: AccessibilityPreferences, arbiter: SpyArbiter) -> HomeStatusService {
    HomeStatusService(
        session: Session(), permissions: nil, safetyModel: Model(), routes: InMemoryRouteStore(),
        arbiter: arbiter,
        preferences: AccessibilityPreferencesService(store: MemoryStore(preferences), arbiter: nil)
    )
}

@Test @MainActor func statusIsNotSpokenOnLaunchWhenTurnedOff() async {
    let arbiter = SpyArbiter()
    let service = home(custom, arbiter: arbiter)
    #expect(await service.announceOnLaunch() == nil)
    #expect(arbiter.received.isEmpty)
    // A pedido («Estado de Lumio») sigue hablando.
    _ = await service.announce()
    #expect(arbiter.received.count == 1)
}

@Test @MainActor func briefAnnouncementsSkipTheUsageTips() async {
    let arbiter = SpyArbiter()
    let brief = await home(custom, arbiter: arbiter).announce()
    let detailed = await home(.standard, arbiter: arbiter).announce()
    #expect(!brief.contains(HomeAnnouncements.quickActions))
    #expect(detailed.contains(HomeAnnouncements.quickActions))
    #expect(brief.hasPrefix("Lumio listo."))
}

@MainActor
private final class Capturer: NarrationFrameCapturing {
    private(set) var calls = 0
    func captureNarrationFrame() async -> NarrationCapture {
        calls += 1
        return .frame(NarrationFrame(jpeg: Data([1]), capturedAt: Date()))
    }
}

private struct Signatures: SceneSignatureProviding {
    func signature(for jpeg: Data) -> SceneSignature? { SceneSignature([1]) }
}

private final class Describer: EnvironmentDescribing, @unchecked Sendable {
    func describe(_ frame: NarrationFrame, trigger: NarrationTrigger, consentVersion: String) async throws -> String { "" }
}

@MainActor
private final class Consent: NarrationConsentGating {
    var consentVersionForUpload: String? { NarrationConsentPolicy.currentVersion }
    func requireConsentBeforeNarration() -> Bool { true }
}

@Test @MainActor func autoNarrationStopsWhenTurnedOff() async {
    let preferences = AccessibilityPreferencesService(store: MemoryStore(), arbiter: nil)
    let capturer = Capturer()
    let service = EnvironmentNarrationService(
        capturer: capturer, describer: Describer(), consent: Consent(),
        connectivity: FakeConnectivity(), arbiter: nil
    )
    let scheduler = AutoNarrationScheduler(
        service: service, capturer: capturer, signatures: Signatures(), consent: Consent(),
        connectivity: FakeConnectivity(), channel: nil,
        isEnabled: { [preferences] in preferences.preferences.autoNarration },
        sleep: { _ in try await Task.sleep(nanoseconds: 60 * 1_000_000_000) }
    )
    scheduler.start()
    defer { scheduler.stop() }
    #expect(await scheduler.tick() == .baselineSet)
    preferences.update(custom)
    #expect(await scheduler.tick() == .skipped(.disabledByUser))
    // Apagada no toma fotos.
    #expect(capturer.calls == 1)
}
