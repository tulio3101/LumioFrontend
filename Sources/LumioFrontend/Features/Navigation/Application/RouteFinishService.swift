import Foundation

/// Finalizar Ruta (SCRUM-10), a mano o al llegar al destino:
///
/// 1. Detiene las instrucciones de la ruta: la que suena y las pendientes (SCRUM-128).
/// 2. La pone en la cola del historial y después borra la copia local, así deja de estar
///    activa sin perderse aunque la app se cierre en medio (SCRUM-131).
/// 3. Anuncia por audio y háptica que la navegación terminó (SCRUM-129).
/// 4. Intenta enviarla al historial del backend; sin red queda pendiente (SCRUM-130).
@MainActor
final class RouteFinishService: RouteFinishing {
    static let contextID = "route-finished"

    private let store: any ActiveRouteStoring
    private let history: any PendingHistorySyncing
    private let arbiter: any AudioArbitrating
    private let haptics: any HapticFeedbackPlaying
    private let now: () -> Date

    init(
        store: any ActiveRouteStoring,
        history: any PendingHistorySyncing,
        arbiter: any AudioArbitrating,
        haptics: (any HapticFeedbackPlaying)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.history = history
        self.arbiter = arbiter
        self.haptics = haptics ?? NoHapticFeedback()
        self.now = now
    }

    func finishActiveRoute(
        outcome: RouteHistoryEntry.Outcome, trigger: RouteFinishTrigger
    ) async -> RouteFinishResult? {
        guard let route = try? store.load() else {
            speak(RouteFinishAnnouncements.noActiveRoute, key: "no-active-route")
            return nil
        }
        let result = RouteFinishResult(
            finished: FinishedRoute(route: route, outcome: outcome, finishedAt: now()), trigger: trigger
        )

        arbiter.cancel(contextIDs: [NavigationInstructionBuilder.contextID(for: route)])
        // Si no se puede encolar (disco lleno), la ruta se finaliza igual en el teléfono.
        try? history.enqueue(result.finished)
        try? store.clear()

        FeedbackCatalog.emit(.routeFinished(result), audio: arbiter, haptics: haptics, now: now())

        // No se espera a la red: la pantalla y el audio ya confirmaron el final.
        Task { [history] in await history.flush() }
        return result
    }

    private func speak(_ text: String, key: String) {
        arbiter.receive(AudioMessage(
            text: text,
            priority: .routeInformation,
            createdAt: now(),
            contextID: Self.contextID,
            deduplicationKey: key
        ))
    }
}
