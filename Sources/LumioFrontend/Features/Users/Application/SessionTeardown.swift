import Foundation

/// Punto ÚNICO para desmontar todo lo de la sesión/ruta activa (SCRUM-360). Lo usan el cierre de
/// sesión (SignOutService), la expiración de sesión / 401 (SessionExpiryCoordinator) y cualquier
/// salida futura como Eliminar Cuenta (SCRUM-7), para no repartir el apagado por las vistas.
@MainActor
protocol SessionTearingDown: AnyObject {
    func tearDown() async
}

/// Detiene en orden: detección de obstáculos (cámara/ARSession), llegada, desvío/recálculo y, con
/// ellos, el GPS compartido; envía lo pendiente de esta cuenta y limpia la ruta local; por último
/// vacía la cola de audio. Trabaja solo con protocolos (sin ARKit/UIKit) para compilar en portable.
@MainActor
final class SessionTeardown: SessionTearingDown {
    /// Detección de obstáculos (SCRUM-33). nil fuera de iOS o si el modelo no cargó.
    private let safetyMonitor: (any SafetyMonitoring)?
    private let arrivalMonitor: any ArrivalMonitoring
    private let deviationMonitor: any RouteDeviationMonitoring
    private let arbiter: (any AudioArbitrating)?
    private let routes: any ActiveRouteStoring
    private let recentRoutes: (any RecentRoutesStoring)?
    /// Rutas finalizadas sin red: se intentan enviar con esta cuenta antes de limpiar; lo que no
    /// llegue se descarta para no subirlo luego con otra.
    private let pendingHistory: (any PendingHistorySyncing)?
    /// SCRUM-25: dejar de compartir la ubicación antes de que se borren los tokens.
    private let locationSharing: (any LocationSharingStopping)?

    init(
        safetyMonitor: (any SafetyMonitoring)? = nil,
        arrivalMonitor: any ArrivalMonitoring,
        deviationMonitor: any RouteDeviationMonitoring,
        arbiter: (any AudioArbitrating)? = nil,
        routes: any ActiveRouteStoring,
        recentRoutes: (any RecentRoutesStoring)? = nil,
        pendingHistory: (any PendingHistorySyncing)? = nil,
        locationSharing: (any LocationSharingStopping)? = nil
    ) {
        self.locationSharing = locationSharing
        self.safetyMonitor = safetyMonitor
        self.arrivalMonitor = arrivalMonitor
        self.deviationMonitor = deviationMonitor
        self.arbiter = arbiter
        self.routes = routes
        self.recentRoutes = recentRoutes
        self.pendingHistory = pendingHistory
    }

    func tearDown() async {
        // 0. SCRUM-25: cerrar el enlace de ubicación con esta cuenta (necesita su sesión).
        await locationSharing?.stopSharing()

        // 1. Parar los productores de la ruta activa ANTES de vaciar el audio, para que no
        //    vuelvan a encolar indicaciones ni alertas después de salir. Parar los dos monitores
        //    apaga el GPS compartido (SharedLocationTracker); stop() de SafetyService pausa y
        //    libera la ARSession (cámara).
        safetyMonitor?.stop()
        arrivalMonitor.stopMonitoring()
        deviationMonitor.stopMonitoring()

        // 2. Enviar lo pendiente de esta cuenta antes de limpiar. Lo que no llegue NO se descarta:
        //    se "aparca" asociado a la cuenta (SCRUM-360) para reenviarlo cuando ese mismo usuario
        //    vuelva a iniciar sesión; otro usuario no lo sube con su cuenta.
        if let pendingHistory {
            _ = await pendingHistory.flush()
            pendingHistory.park()
        }

        // 3. Borrar la ruta activa local y las recientes: otra cuenta en el mismo teléfono no
        //    las ve ni se restaura con ellas.
        try? routes.clear()
        try? recentRoutes?.clear()

        // 4. Vaciar la cola de audio (navegación + seguridad). Va al final para que nada quede
        //    sonando; el aviso "Sesión cerrada" se emite DESPUÉS del reset para que sobreviva.
        arbiter?.resetSession()
        arbiter?.receive(SessionAudio.closed())
    }
}
