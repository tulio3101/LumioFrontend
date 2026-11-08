import Foundation

/// Copia local de la ruta activa en un JSON dentro de Application Support.
struct FileActiveRouteStore: ActiveRouteStoring {
    let fileURL: URL

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Lumio", isDirectory: true)
            .appendingPathComponent("active-route.json")
    }

    // Fechas con la estrategia por defecto: ISO-8601 perdería las fracciones de segundo.
    func load() throws -> ActiveRoute? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(ActiveRoute.self, from: Data(contentsOf: fileURL))
    }

    func save(_ route: ActiveRoute) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        // Legible con el teléfono bloqueado tras el primer desbloqueo: la guía sigue en segundo plano.
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(route).write(to: fileURL, options: options)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
