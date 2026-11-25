import Foundation

/// Preferencias de voz en un JSON dentro de Application Support, junto a la copia de la ruta
/// activa. Es lo primero que se lee al abrir la app, antes de cualquier locución.
struct FileVoicePreferencesStore: VoicePreferencesStoring {
    let fileURL: URL

    /// Misma carpeta que FileActiveRouteStore. No se llama a su defaultFileURL porque es
    /// MainActor (por ActiveRouteStoring) y este almacenamiento no lo es.
    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Lumio", isDirectory: true)
            .appendingPathComponent("voice-preferences.json")
    }

    func load() throws -> VoicePreferences? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(VoicePreferences.self, from: Data(contentsOf: fileURL))
    }

    func save(_ preferences: VoicePreferences) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        // Se lee con el teléfono bloqueado si una alerta suena en segundo plano.
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(preferences).write(to: fileURL, options: options)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
