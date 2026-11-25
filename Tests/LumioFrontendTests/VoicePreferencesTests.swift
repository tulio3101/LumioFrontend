import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

// Configurar Preferencias de Voz Descriptiva: consultar, elegir idioma, voz y velocidad,
// aplicar a todas las locuciones del árbitro, guardar en el teléfono e informar lo que no se
// puede aplicar. Sin voces reales: catálogo, almacenamiento y reproductor falsos.

private let mexico = VoiceLanguageOption(code: "es-MX", name: "Español (México)")
private let spain = VoiceLanguageOption(code: "es-ES", name: "Español (España)")
private let paulina = VoiceOption(id: "voice.paulina", name: "Paulina", language: "es-MX", isEnhanced: false)
private let juan = VoiceOption(id: "voice.juan", name: "Juan", language: "es-MX", isEnhanced: true)
private let monica = VoiceOption(id: "voice.monica", name: "Mónica", language: "es-ES", isEnhanced: false)

private struct FakeCatalog: VoiceCatalogProviding {
    var languages = [mexico, spain]
    var voices = [paulina, juan, monica]

    func availableLanguages() -> [VoiceLanguageOption] { languages }
    func availableVoices(language: String) -> [VoiceOption] { voices.filter { $0.language == language } }
}

private final class MemoryPreferencesStore: VoicePreferencesStoring {
    var saved: VoicePreferences?
    var failLoad = false
    var failSave = false
    private(set) var saves = 0
    private(set) var clears = 0

    init(_ saved: VoicePreferences? = nil) { self.saved = saved }

    func load() throws -> VoicePreferences? {
        if failLoad { throw StubError.failed }
        return saved
    }

    func save(_ preferences: VoicePreferences) throws {
        saves += 1
        if failSave { throw StubError.failed }
        saved = preferences
    }

    func clear() throws {
        clears += 1
        saved = nil
    }
}

/// Reproductor del árbitro que anota con qué preferencias sonó cada mensaje.
@MainActor
private final class RecordingVoicePlayer: AudioPlaying, VoiceOutputConfiguring {
    var onFinished: ((PlaybackToken) -> Void)?
    private(set) var applied: [VoicePreferences] = []
    private(set) var played: [(text: String, priority: AudioPriority, preferences: VoicePreferences)] = []
    private var current = VoicePreferences.standard
    private var active: PlaybackToken?

    func apply(_ preferences: VoicePreferences) {
        applied.append(preferences)
        current = preferences
    }

    func play(_ message: AudioMessage, token: PlaybackToken) throws {
        active = token
        played.append((message.text, message.priority, current))
    }

    func stop() { active = nil }

    func finish() {
        guard let token = active else { return }
        active = nil
        onFinished?(token)
    }
}

@MainActor
private struct PreferencesHarness {
    let store: MemoryPreferencesStore
    let player = RecordingVoicePlayer()
    let arbiter = SpyArbiter()
    let service: VoicePreferencesService

    init(stored: VoicePreferences? = nil, catalog: FakeCatalog = FakeCatalog(), failLoad: Bool = false) {
        let memory = MemoryPreferencesStore(stored)
        memory.failLoad = failLoad
        store = memory
        service = VoicePreferencesService(store: memory, catalog: catalog, output: player, arbiter: arbiter)
    }

    var spoken: [String] { arbiter.received.map(\.text) }
}

// MARK: - Consultar y leer del teléfono

@Test @MainActor func storedPreferencesAreAppliedWhenTheAppOpens() {
    let stored = VoicePreferences(language: "es-ES", voiceIdentifier: monica.id, speechRate: 1.5)
    let harness = PreferencesHarness(stored: stored)

    #expect(harness.service.preferences == stored)
    #expect(harness.player.applied == [stored])
    #expect(harness.service.launchIssues.isEmpty)
    // Abrir la app no locuta nada ni reescribe el archivo.
    #expect(harness.arbiter.received.isEmpty)
    #expect(harness.store.saves == 0)
}

@Test @MainActor func withoutStoredPreferencesTheStandardVoiceIsUsed() {
    let harness = PreferencesHarness()

    #expect(harness.service.preferences == .standard)
    #expect(harness.player.applied == [.standard])
    #expect(harness.service.launchIssues.isEmpty)
}

@Test @MainActor func unreadableFileFallsBackToStandardAndSaysSo() {
    let harness = PreferencesHarness(failLoad: true)

    #expect(harness.service.preferences == .standard)
    #expect(harness.service.launchIssues == [.storedUnreadable])
}

@Test @MainActor func uninstalledVoiceKeepsTheRestOfThePreferences() {
    let stored = VoicePreferences(language: "es-MX", voiceIdentifier: "voice.removed", speechRate: 1.25)
    let harness = PreferencesHarness(stored: stored)

    let expected = VoicePreferences(language: "es-MX", voiceIdentifier: nil, speechRate: 1.25)
    #expect(harness.service.preferences == expected)
    #expect(harness.player.applied == [expected])
    #expect(harness.service.launchIssues == [.voiceUnavailable])
    // Lo guardado no se toca: si se vuelve a instalar la voz, el usuario la elige de nuevo.
    #expect(harness.store.saved == stored)
}

@Test @MainActor func unavailableLanguageAndInvalidRateAreReplacedOnLaunch() {
    let stored = VoicePreferences(language: "es-AR", voiceIdentifier: "voice.ar", speechRate: 9)
    let harness = PreferencesHarness(stored: stored)

    #expect(harness.service.preferences == .standard)
    #expect(harness.service.launchIssues == [.invalidRate, .languageUnavailable("es-AR")])
}

@Test @MainActor func currentPreferencesCanBeConsulted() {
    let stored = VoicePreferences(language: "es-MX", voiceIdentifier: juan.id, speechRate: 1.25)
    let harness = PreferencesHarness(stored: stored)
    let service = harness.service

    let summary = VoicePreferencesAnnouncements.summary(
        language: VoicePreferencesAnnouncements.languageName(
            service.preferences.language, catalog: service.availableLanguages()
        ),
        voice: VoicePreferencesAnnouncements.voiceName(
            service.preferences.voiceIdentifier, voices: service.availableVoices(language: "es-MX")
        ),
        rate: service.preferences.speechRate
    )
    #expect(summary == "Idioma: Español (México). Voz: Juan (mejorada). Velocidad: 1,25 veces.")
    #expect(service.availableLanguages() == [mexico, spain])
    #expect(service.availableVoices(language: "es-MX") == [paulina, juan])
}

// MARK: - Cambiar

@Test @MainActor func changingTheRateAppliesSavesAndConfirmsWithTheNewVoice() {
    let harness = PreferencesHarness()
    var new = VoicePreferences.standard
    new.speechRate = 1.5

    let outcome = harness.service.update(new)

    #expect(outcome == .saved)
    #expect(harness.service.preferences == new)
    #expect(harness.store.saved == new)
    #expect(harness.player.applied.last == new)
    let message = harness.arbiter.received.last
    #expect(message?.text == "Velocidad: 1,5 veces. Así sonará Lumio.")
    #expect(message?.priority == .routeInformation)
    #expect(message?.contextID == VoicePreferencesService.contextID)
}

@Test @MainActor func changingTheLanguageUsesItsDefaultVoice() {
    let harness = PreferencesHarness()

    let outcome = harness.service.update(VoicePreferences(language: "es-ES", voiceIdentifier: nil, speechRate: 1))

    #expect(outcome == .saved)
    #expect(harness.spoken.last == "Idioma: Español (España). Voz: predeterminada. Así sonará Lumio.")
}

@Test @MainActor func choosingAnInstalledVoice() {
    let harness = PreferencesHarness()

    let outcome = harness.service.update(VoicePreferences(language: "es-MX", voiceIdentifier: paulina.id, speechRate: 1))

    #expect(outcome == .saved)
    #expect(harness.player.applied.last?.voiceIdentifier == paulina.id)
    #expect(harness.spoken.last == "Voz: Paulina. Así sonará Lumio.")
}

@Test @MainActor func samePreferencesDoNothing() {
    let harness = PreferencesHarness()

    #expect(harness.service.update(.standard) == .unchanged)
    #expect(harness.store.saves == 0)
    #expect(harness.arbiter.received.isEmpty)
}

@Test @MainActor func eachChangeReplacesThePreviousConfirmation() {
    let harness = PreferencesHarness()

    _ = harness.service.update(VoicePreferences(language: "es-MX", voiceIdentifier: nil, speechRate: 1.25))
    _ = harness.service.update(VoicePreferences(language: "es-MX", voiceIdentifier: nil, speechRate: 1.5))

    #expect(harness.arbiter.cancelledContexts == [[VoicePreferencesService.contextID], [VoicePreferencesService.contextID]])
    #expect(harness.spoken.last == "Velocidad: 1,5 veces. Así sonará Lumio.")
}

@Test @MainActor func previewSpeaksASample() {
    let harness = PreferencesHarness()

    harness.service.preview()

    #expect(harness.spoken == [VoicePreferencesAnnouncements.sample])
    #expect(harness.arbiter.received.last?.priority == .routeInformation)
}

// MARK: - Lo que no se puede aplicar

@Test @MainActor func invalidRateIsRejectedAndNothingChanges() {
    let harness = PreferencesHarness()
    var new = VoicePreferences.standard
    new.speechRate = 3

    let outcome = harness.service.update(new)

    #expect(outcome == .rejected(.invalidRate))
    #expect(harness.service.preferences == .standard)
    #expect(harness.store.saves == 0)
    #expect(harness.player.applied == [.standard])
    #expect(harness.spoken == [
        "Esa velocidad no está disponible. Elige entre 0,5 y 2 veces la normal. No se cambió nada.",
    ])
}

@Test @MainActor func uninstalledVoiceIsRejectedAndSaysHowToGetIt() {
    let harness = PreferencesHarness()

    let outcome = harness.service.update(VoicePreferences(language: "es-MX", voiceIdentifier: monica.id, speechRate: 1))

    #expect(outcome == .rejected(.voiceUnavailable))
    #expect(harness.service.preferences == .standard)
    #expect(harness.spoken.last?.contains("Ajustes, Accesibilidad, Contenido leído, Voces") == true)
}

@Test @MainActor func unavailableLanguageIsRejected() {
    let harness = PreferencesHarness()

    let outcome = harness.service.update(VoicePreferences(language: "es-AR", voiceIdentifier: nil, speechRate: 1))

    #expect(outcome == .rejected(.languageUnavailable("es-AR")))
    #expect(harness.spoken.last == "El idioma Español (Argentina) no está disponible en este teléfono. No se cambió nada.")
}

@Test @MainActor func failedSaveStillAppliesAndWarnsItWillNotLast() {
    let harness = PreferencesHarness()
    harness.store.failSave = true
    var new = VoicePreferences.standard
    new.speechRate = 0.75

    let outcome = harness.service.update(new)

    #expect(outcome == .appliedNotSaved)
    #expect(harness.player.applied.last == new)
    #expect(harness.spoken.last == VoicePreferencesAnnouncements.notSaved)
}

// MARK: - Se conservan al cerrar y abrir la app

@Test @MainActor func preferencesSurviveClosingAndReopeningTheApp() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumio-voice-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileVoicePreferencesStore(fileURL: directory.appendingPathComponent("voice-preferences.json"))
    let chosen = VoicePreferences(language: "es-ES", voiceIdentifier: monica.id, speechRate: 1.75)

    let first = VoicePreferencesService(store: store, catalog: FakeCatalog(), output: nil, arbiter: nil)
    #expect(first.update(chosen) == .saved)

    // Abrir de nuevo: otra instancia con el mismo archivo.
    let player = RecordingVoicePlayer()
    let reopened = VoicePreferencesService(store: store, catalog: FakeCatalog(), output: player, arbiter: nil)
    #expect(reopened.preferences == chosen)
    #expect(player.applied == [chosen])
    #expect(try store.load() == chosen)
}

@Test func fileStoreClearRemovesThePreferences() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumio-voice-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileVoicePreferencesStore(fileURL: directory.appendingPathComponent("voice-preferences.json"))

    #expect(try store.load() == nil)
    try store.save(.standard)
    #expect(try store.load() == .standard)
    try store.clear()
    #expect(try store.load() == nil)
    try store.clear()
}

// MARK: - Todas las locuciones del árbitro

@Test @MainActor func safetyNavigationAndNarrationAllUseThePreferences() {
    let player = RecordingVoicePlayer()
    let arbiter = AudioArbiterService(player: player)
    let service = VoicePreferencesService(
        store: MemoryPreferencesStore(), catalog: FakeCatalog(), output: player, arbiter: arbiter
    )
    let chosen = VoicePreferences(language: "es-ES", voiceIdentifier: monica.id, speechRate: 1.5)
    #expect(service.update(chosen) == .saved)
    player.finish()

    arbiter.receive(AudioMessage(text: "Obstáculo al frente", priority: .immediateRisk))
    player.finish()
    arbiter.receive(AudioMessage(text: "Gira a la derecha", priority: .routeInformation))
    player.finish()
    arbiter.receive(AudioMessage(text: "Hay una cafetería a tu izquierda", priority: .environmentInformation))
    player.finish()

    let afterChange = player.played.dropFirst()
    #expect(afterChange.map(\.priority) == [.immediateRisk, .routeInformation, .environmentInformation])
    #expect(afterChange.allSatisfy { $0.preferences == chosen })
}

@Test @MainActor func criticalAlertInterruptsTheConfirmation() {
    let player = RecordingVoicePlayer()
    let arbiter = AudioArbiterService(player: player)
    let service = VoicePreferencesService(
        store: MemoryPreferencesStore(), catalog: FakeCatalog(), output: player, arbiter: arbiter
    )
    var new = VoicePreferences.standard
    new.speechRate = 1.25
    _ = service.update(new)
    #expect(arbiter.currentMessage?.contextID == VoicePreferencesService.contextID)

    arbiter.receive(AudioMessage(text: "Escalón abajo", priority: .immediateRisk))

    #expect(arbiter.currentMessage?.text == "Escalón abajo")
    #expect(player.played.last?.preferences == new)
}

// MARK: - Velocidad y textos

@Test func rateMapsToTheSystemRange() {
    let rate: (Double) -> Float = { SpeechRatePolicy.utteranceRate(for: $0, normal: 0.5, minimum: 0, maximum: 1) }
    #expect(rate(1) == 0.5)
    #expect(rate(0.5) == 0.25)
    #expect(rate(2) == 1)
    // Valores fuera de rango no llegan al sistema: se usa la normal.
    #expect(rate(5) == 0.5)
    #expect(rate(.nan) == 0.5)
}

@Test func rateNamesUseDecimalComma() {
    #expect(SpeechRatePolicy.spokenName(for: 1) == "normal")
    #expect(SpeechRatePolicy.spokenName(for: 0.5) == "0,5 veces")
    #expect(SpeechRatePolicy.spokenName(for: 1.25) == "1,25 veces")
    #expect(SpeechRatePolicy.spokenName(for: 2) == "2 veces")
    #expect(SpeechRatePolicy.isValid(0.5) && SpeechRatePolicy.isValid(2))
    #expect(!SpeechRatePolicy.isValid(0.25) && !SpeechRatePolicy.isValid(2.25))
}

@Test func languageNames() {
    #expect(VoiceLanguageNames.name(for: "es-MX") == "Español (México)")
    #expect(VoiceLanguageNames.name(for: "es-ES") == "Español (España)")
    #expect(VoiceLanguageNames.name(for: "es-CO") == "Español (Colombia)")
    #expect(VoiceLanguageNames.name(for: "en-US") == "en-US")
}

@Test func withoutCatalogOnlyTheRateIsChecked() {
    let chosen = VoicePreferences(language: "es-CL", voiceIdentifier: "x", speechRate: 1)
    #expect(VoicePreferencesPolicy.issue(with: chosen, catalog: NoVoiceCatalog()) == nil)
    var invalid = chosen
    invalid.speechRate = 0
    #expect(VoicePreferencesPolicy.issue(with: invalid, catalog: NoVoiceCatalog()) == .invalidRate)
}

// MARK: - Eliminar Cuenta

@Test @MainActor func deletingTheAccountForgetsTheVoicePreferences() async {
    let stored = VoicePreferences(language: "es-ES", voiceIdentifier: monica.id, speechRate: 2)
    let preferences = PreferencesHarness(stored: stored)
    let routes = InMemoryRouteStore()
    let deletion = AccountDeletionService(
        remote: FakeAccountRemover(),
        tokens: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")),
        routes: routes,
        voicePreferences: preferences.service,
        arbiter: SpyArbiter()
    )

    let outcome = await deletion.deleteAccount()
    #expect(outcome == .deleted)
    #expect(preferences.store.saved == nil)
    #expect(preferences.service.preferences == .standard)
    #expect(preferences.player.applied.last == .standard)
}

@Test @MainActor func failedDeletionKeepsTheVoicePreferences() async {
    let stored = VoicePreferences(language: "es-ES", voiceIdentifier: monica.id, speechRate: 2)
    let preferences = PreferencesHarness(stored: stored)
    let remote = FakeAccountRemover()
    remote.result = .failure(URLError(.notConnectedToInternet))
    let deletion = AccountDeletionService(
        remote: remote,
        tokens: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")),
        routes: InMemoryRouteStore(),
        voicePreferences: preferences.service,
        arbiter: SpyArbiter()
    )

    let outcome = await deletion.deleteAccount()
    #expect(outcome == .offline)
    #expect(preferences.store.saved == stored)
    #expect(preferences.service.preferences == stored)
}
