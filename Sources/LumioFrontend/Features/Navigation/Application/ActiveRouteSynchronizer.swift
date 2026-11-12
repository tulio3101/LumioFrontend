import Foundation

/// Lleva al backend lo que la copia local tiene pendiente: la ruta nueva (PUT active) o el
/// último cambio de destino (PUT {id}/destination). Un fallo nunca invalida la ruta: queda
/// pendiente y se reintenta al restaurarla.
@MainActor
struct ActiveRouteSynchronizer {
    let sync: any ActiveRouteSyncing
    let store: any ActiveRouteStoring
    /// Rutas finalizadas sin red. Van antes que una ruta nueva: al subirla, el backend
    /// cancelaría la anterior que sigue abierta y perdería que se completó.
    var history: (any PendingHistorySyncing)?

    func synchronize(_ route: ActiveRoute) async -> ActiveRoute {
        guard route.isPendingBackendSync else { return route }
        if let history { await history.flush() }
        var synced = route
        do {
            if let remoteID = route.remoteID {
                do {
                    try await sync.updateDestination(of: route, remoteID: remoteID)
                } catch ActiveRouteSyncError.routeNoLongerOpen {
                    // Se cerró en el servidor (p. ej. desde otro dispositivo): se guarda como
                    // ruta nueva para que el recorrido actual no se pierda.
                    synced.remoteID = try await sync.upload(route)
                }
            } else {
                synced.remoteID = try await sync.upload(route)
            }
            synced.hasPendingDestinationChange = false
        } catch {
            return route
        }
        saveIfStillCurrent(synced)
        return synced
    }

    /// Mientras se esperaba al backend el usuario pudo cambiar otra vez el destino: no
    /// sobrescribir una versión más nueva de la copia local.
    private func saveIfStillCurrent(_ route: ActiveRoute) {
        guard let stored = try? store.load(), stored.id == route.id, stored.revision == route.revision else {
            return
        }
        try? store.save(route)
    }
}
