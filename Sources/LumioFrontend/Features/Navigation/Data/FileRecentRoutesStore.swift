import Foundation

/// Última lista de destinos recientes en un JSON dentro de Application Support, junto a la
/// copia de la ruta activa.
struct FileRecentRoutesStore: RecentRoutesStoring {
    let fileURL: URL

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        FileActiveRouteStore.defaultFileURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("recent-routes.json")
    }

    func load() throws -> SavedRecentRoutes? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(SavedRecentRoutes.self, from: Data(contentsOf: fileURL))
    }

    func save(_ routes: SavedRecentRoutes) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(routes).write(to: fileURL, options: options)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
