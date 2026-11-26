import Foundation

/// Qué preferencias faltan por subir al backend, en un JSON junto a las preferencias.
struct FilePreferencesSyncStateStore: PreferencesSyncStateStoring {
    let fileURL: URL

    /// Misma carpeta que FileActiveRouteStore, sin llamar a su defaultFileURL (es MainActor).
    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Lumio", isDirectory: true)
            .appendingPathComponent("preferences-sync.json")
    }

    func load() throws -> PreferencesSyncState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(PreferencesSyncState.self, from: Data(contentsOf: fileURL))
    }

    func save(_ state: PreferencesSyncState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(state).write(to: fileURL, options: options)
    }
}
