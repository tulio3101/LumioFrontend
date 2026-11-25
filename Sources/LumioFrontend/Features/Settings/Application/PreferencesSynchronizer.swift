import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sincroniza en segundo plano las preferencias de voz y vibración con el backend.
///
/// - Cada cambio guardado en el teléfono queda pendiente y se sube (PUT). Sin red, sin sesión o
///   con error del servidor sigue pendiente y se reintenta al volver la conexión, al abrir la
///   app o al iniciar sesión. Un rechazo de validación (422) se descarta: reintentar daría lo
///   mismo.
/// - Sin cambios pendientes, al abrir la app o iniciar sesión se bajan (GET) y se aplican solo si
///   son más recientes que las del teléfono.
/// - Nada de esto bloquea ni retrasa el audio: las preferencias ya están aplicadas en memoria.
@MainActor
final class PreferencesSynchronizer {
    private let remote: any PreferencesRemoting
    private let stateStore: any PreferencesSyncStateStoring
    private let voice: any SyncableVoicePreferences
    private let haptics: any SyncableHapticPreferences
    private let now: () -> Date
    private(set) var state: PreferencesSyncState
    private var inFlight: Task<PreferencesSyncOutcome, Never>?

    init(
        remote: any PreferencesRemoting,
        stateStore: any PreferencesSyncStateStoring,
        voice: any SyncableVoicePreferences,
        haptics: any SyncableHapticPreferences,
        now: @escaping () -> Date = Date.init
    ) {
        self.remote = remote
        self.stateStore = stateStore
        self.voice = voice
        self.haptics = haptics
        self.now = now
        let stored = try? stateStore.load()
        state = stored ?? .empty
    }

    /// Lo llaman los servicios de voz y vibración después de un cambio del usuario.
    func localPreferencesChanged() {
        markLocalChange()
        Task {
            await synchronize()
            // Si ya había una sincronización en curso, esta subida va después.
            if state.pending { await synchronize() }
        }
    }

    /// Deja el cambio pendiente de subir (sin subirlo todavía).
    func markLocalChange() {
        state = PreferencesSyncState(localUpdatedAt: now(), pending: true)
        persist()
    }

    /// Una sola sincronización a la vez: quien llega mientras corre espera a la misma.
    @discardableResult
    func synchronize() async -> PreferencesSyncOutcome {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.run() }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    /// Al cerrar sesión o eliminar la cuenta: la próxima cuenta empieza por lo de su backend.
    func forgetAccount() {
        state = .empty
        persist()
    }

    private func run() async -> PreferencesSyncOutcome {
        if state.pending {
            return await push()
        }
        return await pull()
    }

    private func push() async -> PreferencesSyncOutcome {
        let current = SyncedPreferences(voice: voice.preferences, haptics: haptics.preferences)
        let changedAt = state.localUpdatedAt
        do {
            let savedAt = try await remote.save(current)
            // Si hubo otro cambio mientras subía, sigue pendiente.
            guard state.localUpdatedAt == changedAt else { return .failed }
            state = PreferencesSyncState(localUpdatedAt: savedAt ?? changedAt, pending: false)
            persist()
            return .pushed
        } catch where Self.isPermanent(error) {
            state.pending = false
            persist()
            return .failed
        } catch {
            return .failed
        }
    }

    private func pull() async -> PreferencesSyncOutcome {
        let remotePreferences: RemotePreferences
        do {
            remotePreferences = try await remote.load()
        } catch {
            return .failed
        }
        // Un cambio del teléfono mientras se consultaba gana.
        guard !state.pending, let remoteDate = remotePreferences.updatedAt else { return .upToDate }
        if let local = state.localUpdatedAt, local >= remoteDate { return .upToDate }
        voice.applySynced(remotePreferences.preferences.voice)
        haptics.applySynced(remotePreferences.preferences.haptics)
        state = PreferencesSyncState(localUpdatedAt: remoteDate, pending: false)
        persist()
        return .pulled
    }

    private func persist() {
        try? stateStore.save(state)
    }

    /// El backend rechazó los datos: reintentar daría el mismo resultado.
    nonisolated static func isPermanent(_ error: Error) -> Bool {
        switch error {
        case HTTPClientError.statusCode(let code):
            return code == 400 || code == 422
        default:
            return false
        }
    }
}
