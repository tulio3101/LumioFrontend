import Foundation

/// Cerrar sesión desde la app: desmonta todo lo de la ruta activa (detección, monitores, audio y
/// datos locales) por el punto central `SessionTeardown` y luego revoca la sesión en el backend.
@MainActor
protocol SigningOut {
    func signOut() async
}

@MainActor
struct SignOutService: SigningOut {
    let session: any SessionEnding
    let teardown: any SessionTearingDown

    /// Init principal: reutiliza el teardown central (SCRUM-360).
    init(session: any SessionEnding, teardown: any SessionTearingDown) {
        self.session = session
        self.teardown = teardown
    }

    /// Init de conveniencia sin monitores (plataformas sin detección o pruebas de almacenamiento):
    /// arma un `SessionTeardown` con monitores No-op.
    init(
        session: any SessionEnding,
        routes: any ActiveRouteStoring,
        arbiter: (any AudioArbitrating)?,
        recentRoutes: (any RecentRoutesStoring)? = nil,
        pendingHistory: (any PendingHistorySyncing)? = nil
    ) {
        self.init(
            session: session,
            teardown: SessionTeardown(
                arrivalMonitor: NoArrivalMonitoring(),
                deviationMonitor: NoDeviationMonitoring(),
                arbiter: arbiter, routes: routes,
                recentRoutes: recentRoutes, pendingHistory: pendingHistory
            )
        )
    }

    func signOut() async {
        // Primero el desmonte (envía lo pendiente con el token aún válido y detiene todo), luego
        // revocar la sesión y borrar los tokens.
        await teardown.tearDown()
        await session.endSession()
    }
}
