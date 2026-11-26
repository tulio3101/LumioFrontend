import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

// Respaldo de las preferencias de voz y vibración en GET/PUT /users/me/preferences: subir los
// cambios del teléfono en segundo plano, reintentar sin red, bajar las más recientes y no
// volver a subir lo que llegó del backend.

private final class VoiceStore: VoicePreferencesStoring {
    var saved: VoicePreferences?
    func load() throws -> VoicePreferences? { saved }
    func save(_ preferences: VoicePreferences) throws { saved = preferences }
    func clear() throws { saved = nil }
}

private final class HapticStore: HapticPreferencesStoring {
    var saved: HapticPreferences?
    func load() throws -> HapticPreferences? { saved }
    func save(_ preferences: HapticPreferences) throws { saved = preferences }
    func clear() throws { saved = nil }
}

private final class StateStore: PreferencesSyncStateStoring {
    var saved: PreferencesSyncState?
    func load() throws -> PreferencesSyncState? { saved }
    func save(_ state: PreferencesSyncState) throws { saved = state }
}

private final class FakeRemote: PreferencesRemoting {
    var stored: RemotePreferences
    var saveError: Error?
    var loadError: Error?
    var savedAt: Date
    private(set) var saves: [SyncedPreferences] = []
    private(set) var loads = 0

    init(stored: RemotePreferences, savedAt: Date) {
        self.stored = stored
        self.savedAt = savedAt
    }

    func load() async throws -> RemotePreferences {
        loads += 1
        if let loadError { throw loadError }
        return stored
    }

    func save(_ preferences: SyncedPreferences) async throws -> Date? {
        if let saveError { throw saveError }
        saves.append(preferences)
        stored = RemotePreferences(preferences: preferences, updatedAt: savedAt)
        return savedAt
    }
}

private let t0 = Date(timeIntervalSince1970: 1_000)
private let neverSaved = RemotePreferences(
    preferences: SyncedPreferences(voice: .standard, haptics: .standard), updatedAt: nil
)
private let fromOtherPhone = SyncedPreferences(
    voice: VoicePreferences(language: "es-ES", voiceIdentifier: nil, speechRate: 1.5),
    haptics: HapticPreferences(isEnabled: false, intensity: .strong, disabledCues: [.routeReady])
)

@MainActor
private struct SyncHarness {
    let voiceStore = VoiceStore()
    let hapticStore = HapticStore()
    let stateStore = StateStore()
    let remote: FakeRemote
    let voice: VoicePreferencesService
    let haptics: HapticPreferencesService
    let sync: PreferencesSynchronizer

    init(remote stored: RemotePreferences = neverSaved, state: PreferencesSyncState? = nil) {
        remote = FakeRemote(stored: stored, savedAt: t0.addingTimeInterval(60))
        stateStore.saved = state
        voice = VoicePreferencesService(store: voiceStore, catalog: NoVoiceCatalog(), output: nil, arbiter: nil)
        haptics = HapticPreferencesService(store: hapticStore, player: nil, arbiter: nil)
        sync = PreferencesSynchronizer(
            remote: remote, stateStore: stateStore, voice: voice, haptics: haptics, now: { t0 }
        )
        // Solo marca el cambio: cada prueba decide cuándo sincronizar (sin tareas sueltas).
        let synchronizer = sync
        voice.onPreferencesChanged = { synchronizer.markLocalChange() }
        haptics.onPreferencesChanged = { synchronizer.markLocalChange() }
    }
}

// MARK: - Subir los cambios del teléfono

@Test @MainActor func aLocalChangeIsMarkedPendingAndUploaded() async {
    let harness = SyncHarness()
    var faster = VoicePreferences.standard
    faster.speechRate = 1.25

    _ = harness.voice.update(faster)
    #expect(harness.stateStore.saved?.pending == true)
    let outcome = await harness.sync.synchronize()

    #expect(outcome == .pushed)
    #expect(harness.remote.saves.last?.voice == faster)
    #expect(harness.remote.saves.last?.haptics == .standard)
    #expect(harness.sync.state == PreferencesSyncState(localUpdatedAt: t0.addingTimeInterval(60), pending: false))
}

@Test @MainActor func withoutNetworkTheChangeStaysPendingAndIsRetried() async {
    let harness = SyncHarness()
    harness.remote.saveError = URLError(.notConnectedToInternet)
    var off = HapticPreferences.standard
    off.isEnabled = false

    _ = harness.haptics.update(off)
    let offline = await harness.sync.synchronize()
    #expect(offline == .failed)
    #expect(harness.stateStore.saved?.pending == true)

    harness.remote.saveError = nil
    let online = await harness.sync.synchronize()

    #expect(online == .pushed)
    #expect(harness.remote.saves.last?.haptics == off)
    #expect(harness.sync.state.pending == false)
}

@Test @MainActor func aRejectedUploadIsNotRetried() async {
    let harness = SyncHarness()
    harness.remote.saveError = HTTPClientError.statusCode(422)
    var faster = VoicePreferences.standard
    faster.speechRate = 1.5

    _ = harness.voice.update(faster)
    _ = await harness.sync.synchronize()

    #expect(harness.sync.state.pending == false)
    // Lo del teléfono sigue aplicado.
    #expect(harness.voice.preferences == faster)
}

// MARK: - Bajar las del backend

@Test @MainActor func newerRemotePreferencesAreAppliedWithoutUploadingThemAgain() async {
    let harness = SyncHarness(remote: RemotePreferences(preferences: fromOtherPhone, updatedAt: t0))

    let outcome = await harness.sync.synchronize()

    #expect(outcome == .pulled)
    #expect(harness.voice.preferences == fromOtherPhone.voice)
    #expect(harness.haptics.preferences == fromOtherPhone.haptics)
    #expect(harness.voiceStore.saved == fromOtherPhone.voice)
    #expect(harness.hapticStore.saved == fromOtherPhone.haptics)
    #expect(harness.sync.state == PreferencesSyncState(localUpdatedAt: t0, pending: false))
    #expect(harness.remote.saves.isEmpty)
}

@Test @MainActor func olderRemotePreferencesDoNotReplaceThePhone() async {
    let harness = SyncHarness(
        remote: RemotePreferences(preferences: fromOtherPhone, updatedAt: t0),
        state: PreferencesSyncState(localUpdatedAt: t0.addingTimeInterval(10), pending: false)
    )

    let outcome = await harness.sync.synchronize()

    #expect(outcome == .upToDate)
    #expect(harness.voice.preferences == .standard)
}

@Test @MainActor func anAccountThatNeverSavedKeepsThePhonePreferences() async {
    let harness = SyncHarness()

    let outcome = await harness.sync.synchronize()

    #expect(outcome == .upToDate)
    #expect(harness.voice.preferences == .standard)
    #expect(harness.remote.loads == 1)
}

@Test @MainActor func pendingChangesWinOverTheBackend() async {
    let harness = SyncHarness(remote: RemotePreferences(preferences: fromOtherPhone, updatedAt: t0))
    var faster = VoicePreferences.standard
    faster.speechRate = 1.75

    _ = harness.voice.update(faster)
    _ = await harness.sync.synchronize()

    #expect(harness.voice.preferences == faster)
    #expect(harness.remote.stored.preferences.voice == faster)
}

@Test @MainActor func signingOutForgetsTheAccountSoTheNextOneDownloadsItsOwn() async {
    let harness = SyncHarness(
        remote: RemotePreferences(preferences: fromOtherPhone, updatedAt: t0),
        state: PreferencesSyncState(localUpdatedAt: t0.addingTimeInterval(10), pending: true)
    )

    harness.sync.forgetAccount()
    let outcome = await harness.sync.synchronize()

    #expect(harness.stateStore.saved?.pending == false)
    #expect(outcome == .pulled)
    #expect(harness.remote.saves.isEmpty)
}

@Test @MainActor func failedDownloadChangesNothing() async {
    let harness = SyncHarness(remote: RemotePreferences(preferences: fromOtherPhone, updatedAt: t0))
    harness.remote.loadError = URLError(.timedOut)

    let outcome = await harness.sync.synchronize()

    #expect(outcome == .failed)
    #expect(harness.voice.preferences == .standard)
    #expect(harness.sync.state == .empty)
}

// MARK: - Contrato con el backend

@Test func preferencesAreSentInTheBackendFormat() throws {
    let preferences = SyncedPreferences(
        voice: VoicePreferences(language: "es-MX", voiceIdentifier: nil, speechRate: 1.25),
        haptics: HapticPreferences(
            isEnabled: true, intensity: .soft, disabledCues: [.routeFinished, .routeReady, .criticalAlert]
        )
    )

    let data = try JSONEncoder().encode(PreferencesDTO(preferences))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(json["voice_language"] as? String == "es-MX")
    #expect(json["speech_rate"] as? Double == 1.25)
    #expect(json["haptic_intensity"] as? String == "soft")
    // Solo los eventos configurables y en orden estable; el backend rechaza los demás.
    #expect(json["haptic_disabled_events"] as? [String] == ["routeFinished", "routeReady"])
    #expect(json.keys.contains("voice_identifier"))
    // El backend rechaza campos de más.
    #expect(!json.keys.contains("updated_at"))
}

@Test func backendPreferencesAreRead() throws {
    let body = """
    {"voice_language": "es-ES", "voice_identifier": "voice.monica", "speech_rate": 0.75,
     "haptics_enabled": false, "haptic_intensity": "strong",
     "haptic_disabled_events": ["routeFailed", "algoNuevo"],
     "updated_at": "2026-11-25T21:03:04.250000Z"}
    """
    let remote = try JSONDecoder().decode(PreferencesDTO.self, from: Data(body.utf8)).remote

    #expect(remote.preferences.voice == VoicePreferences(language: "es-ES", voiceIdentifier: "voice.monica", speechRate: 0.75))
    #expect(remote.preferences.haptics == HapticPreferences(isEnabled: false, intensity: .strong, disabledCues: [.routeFailed]))
    #expect(remote.updatedAt == BackendDate.parse("2026-11-25T21:03:04.250Z"))
    #expect(remote.updatedAt != nil)
}

@Test func remoteServiceUsesUsersMePreferences() async throws {
    let response = """
    {"voice_language": "es-MX", "voice_identifier": null, "speech_rate": 1.0,
     "haptics_enabled": true, "haptic_intensity": "medium", "haptic_disabled_events": [],
     "updated_at": null}
    """
    let client = FakeHTTPClient(response: .success(Data(response.utf8)))
    let service = RemotePreferencesService(client: client, baseURL: URL(string: "http://localhost:8000")!)

    let loaded = try await service.load()
    _ = try await service.save(loaded.preferences)

    #expect(loaded.updatedAt == nil)
    #expect(client.requests.map(\.httpMethod) == ["GET", "PUT"])
    #expect(client.requests.allSatisfy { $0.url?.path == "/users/me/preferences" })
}

@Test func withoutBackendPreferencesAreUnavailable() async {
    await #expect(throws: FeatureUnavailable.self) {
        try await RemotePreferencesService(client: FakeHTTPClient(response: .success(Data())), baseURL: nil)
            .load()
    }
}
