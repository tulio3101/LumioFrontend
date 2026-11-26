import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Lleva al historial del backend las rutas finalizadas en el teléfono, en orden (SCRUM-130).
///
/// - Ruta que ya estaba en el backend: si su último cambio de destino o recálculo no había
///   llegado, se envía primero; después POST /places/routes/{id}/finish. Si el backend ya no la tiene
///   (404) o ya no está abierta para cambiar el destino, se guarda como ruta finalizada.
/// - Ruta que nunca llegó: POST /places/routes/history con el id del teléfono (reenviarla
///   no la duplica).
/// - Un fallo de red detiene la cola y se reintenta después. Un rechazo definitivo (4xx de
///   validación o un id ajeno) descarta esa ruta para no bloquear las demás.
@MainActor
final class FinishedRouteSynchronizer: PendingHistorySyncing {
    private let store: any FinishedRoutesStoring
    private let finishSync: any FinishedRouteSyncing
    private let routeSync: any ActiveRouteSyncing
    /// SCRUM-360: de quién es lo pendiente. nil = sin sistema de cuentas (se envía como antes).
    private let account: (any CurrentAccountStoring)?
    private var inFlight: Task<Bool, Never>?

    init(
        store: any FinishedRoutesStoring,
        finishSync: any FinishedRouteSyncing,
        routeSync: any ActiveRouteSyncing,
        account: (any CurrentAccountStoring)? = nil
    ) {
        self.store = store
        self.finishSync = finishSync
        self.routeSync = routeSync
        self.account = account
    }

    func enqueue(_ finished: FinishedRoute) throws {
        try store.save(((try? store.load()) ?? []) + [finished])
    }

    /// Una sola sincronización a la vez: quien llega mientras corre espera a la misma.
    @discardableResult
    func flush() async -> Bool {
        // SCRUM-360: si lo pendiente está aparcado a nombre de una cuenta que NO es la actual,
        // no se envía (otro usuario no sube las rutas del anterior). Se enviará cuando vuelva el dueño.
        if let account, let owner = account.pendingOwnerAccountID, owner != account.currentAccountID {
            return true
        }
        if let inFlight { return await inFlight.value }
        let task = Task { await self.flushPending() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        // Entregado todo lo del dueño actual: ya no está aparcado.
        if result, account?.pendingOwnerAccountID != nil { account?.pendingOwnerAccountID = nil }
        return result
    }

    func discardPending() {
        try? store.save([])
    }

    func park() {
        // No se descarta: se marca a qué cuenta pertenece (la que se va) y se deja de considerar
        // "de la sesión actual" (currentAccountID se limpia) para que otro usuario no lo suba.
        guard let account else { return }
        account.pendingOwnerAccountID = account.currentAccountID
        account.currentAccountID = nil
    }

    private func flushPending() async -> Bool {
        while let next = (try? store.load())?.first {
            do {
                try await send(next)
            } catch where Self.isPermanent(error) {
                // Se descarta: reintentar daría el mismo rechazo.
            } catch {
                return false
            }
            remove(next)
        }
        return true
    }

    private func send(_ finished: FinishedRoute) async throws {
        let route = finished.route
        guard let remoteID = route.remoteID else {
            try await record(finished)
            return
        }
        if route.hasPendingDestinationChange || route.hasPendingReroute {
            do {
                try await routeSync.pushPendingChanges(of: route, remoteID: remoteID)
            } catch ActiveRouteSyncError.routeNoLongerOpen {
                try await record(finished)
                return
            }
        }
        do {
            try await finishSync.finish(remoteID: remoteID, outcome: finished.outcome, finishedAt: finished.finishedAt)
        } catch FinishedRouteSyncError.routeNotFound {
            try await record(finished)
        }
    }

    private func record(_ finished: FinishedRoute) async throws {
        do {
            try await finishSync.record(finished)
        } catch FinishedRouteSyncError.idConflict {
            // El id es de otra cuenta: no se puede guardar en esta.
        }
    }

    /// Mientras se enviaba pudieron llegar más: se quita solo la enviada.
    private func remove(_ finished: FinishedRoute) {
        var pending = (try? store.load()) ?? []
        if let index = pending.firstIndex(of: finished) {
            pending.remove(at: index)
            try? store.save(pending)
        }
    }

    /// 4xx que no se arreglan reintentando. 401 (sesión), 408 y 429 sí pueden resolverse.
    private static func isPermanent(_ error: Error) -> Bool {
        guard case let HTTPClientError.statusCode(code) = error else { return false }
        return (400..<500).contains(code) && ![401, 408, 429].contains(code)
    }
}
