import Foundation

/// Cola de rutas finalizadas pendientes de enviar al historial, en un JSON dentro de
/// Application Support junto a la copia de la ruta activa.
struct FileFinishedRoutesStore: FinishedRoutesStoring {
    let fileURL: URL

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        FileActiveRouteStore.defaultFileURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("pending-finished-routes.json")
    }

    func load() throws -> [FinishedRoute] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([FinishedRoute].self, from: Data(contentsOf: fileURL))
    }

    func save(_ routes: [FinishedRoute]) throws {
        guard !routes.isEmpty else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(routes).write(to: fileURL, options: options)
    }
}
