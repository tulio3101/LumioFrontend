import Foundation

/// Consultar Rutas Recientes (SCRUM-24).
///
/// - El backend es la fuente: guarda cada ruta que deja de estar abierta (completada o
///   cancelada al iniciar otra).
/// - Los destinos se agrupan por lugar, de la vez más reciente a la más antigua.
/// - Cada lista recibida se guarda en el teléfono; sin conexión se usa esa copia y se avisa.
/// - Con `announce`, la respuesta se locuta por el AudioArbiter, también si no hay rutas.
@MainActor
final class RecentRoutesService: RecentRoutesQuerying {
    static let contextID = "recent-routes"

    private let history: any RouteHistoryFetching
    private let store: any RecentRoutesStoring
    private let arbiter: any AudioArbitrating
    private let now: () -> Date

    init(
        history: any RouteHistoryFetching,
        store: any RecentRoutesStoring,
        arbiter: any AudioArbitrating,
        now: @escaping () -> Date = Date.init
    ) {
        self.history = history
        self.store = store
        self.arbiter = arbiter
        self.now = now
    }

    func recentRoutes(announce: Bool) async throws -> RecentRoutes {
        let routes: RecentRoutes
        do {
            let entries = try await history.recentHistory(limit: RecentRoutesPolicy.fetchLimit)
            let destinations = RecentRoutesPolicy.grouped(entries)
            // Si no se puede guardar la copia, la lista igual se muestra.
            try? store.save(SavedRecentRoutes(destinations: destinations, savedAt: now()))
            routes = RecentRoutes(destinations: destinations, source: .backend)
        } catch {
            guard let saved = try? store.load() else {
                if announce { speak(RecentRoutesAnnouncements.unavailable) }
                throw RecentRoutesError.unavailable
            }
            routes = RecentRoutes(destinations: saved.destinations, source: .savedCopy(savedAt: saved.savedAt))
        }
        if announce { speak(RecentRoutesAnnouncements.text(for: routes)) }
        return routes
    }

    private func speak(_ text: String) {
        arbiter.receive(AudioMessage(
            text: text,
            priority: .routeInformation,
            createdAt: now(),
            contextID: Self.contextID,
            // Abrir la pantalla dos veces seguidas no repite el anuncio.
            deduplicationKey: "recent-routes"
        ))
    }
}
