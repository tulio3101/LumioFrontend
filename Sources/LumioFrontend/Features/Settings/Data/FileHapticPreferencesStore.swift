import Foundation

/// Preferencias hápticas en un JSON dentro de Application Support, junto a las de voz.
struct FileHapticPreferencesStore: HapticPreferencesStoring {
    let fileURL: URL

    /// Misma carpeta que FileActiveRouteStore, sin llamar a su defaultFileURL (es MainActor).
    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Lumio", isDirectory: true)
            .appendingPathComponent("haptic-preferences.json")
    }

    func load() throws -> HapticPreferences? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(HapticPreferences.self, from: Data(contentsOf: fileURL))
    }

    func save(_ preferences: HapticPreferences) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(preferences).write(to: fileURL, options: options)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
