import Foundation

/// Copia de respaldo en el backend de las preferencias de voz y vibración
/// (GET/PUT /users/me/preferences). El teléfono es siempre la fuente al abrir la app: aplicar
/// nunca espera a la red. La copia permite recuperarlas al reinstalar o entrar desde otro
/// teléfono.
struct SyncedPreferences: Equatable {
    var voice: VoicePreferences
    var haptics: HapticPreferences
}

struct RemotePreferences: Equatable {
    var preferences: SyncedPreferences
    /// nil si la cuenta nunca guardó preferencias en el backend.
    var updatedAt: Date?
}

protocol PreferencesRemoting {
    func load() async throws -> RemotePreferences
    /// Devuelve cuándo quedaron guardadas en el backend.
    func save(_ preferences: SyncedPreferences) async throws -> Date?
}

/// Qué falta subir, guardado en el teléfono para sobrevivir a cerrar la app sin red.
struct PreferencesSyncState: Codable, Equatable {
    /// Cuándo cambiaron por última vez en el teléfono o se bajaron del backend.
    var localUpdatedAt: Date?
    /// Hay un cambio del teléfono que aún no llegó al backend.
    var pending: Bool

    static let empty = PreferencesSyncState(localUpdatedAt: nil, pending: false)
}

protocol PreferencesSyncStateStoring {
    func load() throws -> PreferencesSyncState?
    func save(_ state: PreferencesSyncState) throws
}

/// Voz y vibración aceptan lo que llega del backend sin volver a subirlo ni locutar nada.
@MainActor
protocol SyncableVoicePreferences: AnyObject {
    var preferences: VoicePreferences { get }
    func applySynced(_ preferences: VoicePreferences)
}

@MainActor
protocol SyncableHapticPreferences: AnyObject {
    var preferences: HapticPreferences { get }
    func applySynced(_ preferences: HapticPreferences)
}

enum PreferencesSyncOutcome: Equatable {
    /// El cambio del teléfono quedó en el backend.
    case pushed
    /// Se aplicaron las del backend porque eran más recientes.
    case pulled
    /// No había nada que hacer.
    case upToDate
    /// Sin red, sin sesión o error del servidor: se reintenta después.
    case failed
}
