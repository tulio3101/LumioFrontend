import Foundation

/// Cuándo el usuario se salió de la ruta y cuándo recalcularla (Recalcular Ruta, SCRUM-26).
///
/// Valores iniciales acordados por el equipo; se validan en pruebas de campo.
struct DeviationPolicy: Equatable {
    /// Una lectura cuenta como desviada si queda a más de esta distancia del trayecto.
    var offRouteThresholdMeters = 30.0
    /// Las lecturas menos precisas no cuentan ni reinician la cuenta: un salto del GPS no
    /// dispara el recálculo.
    var maximumAccuracyMeters = 20.0
    /// Lecturas precisas seguidas fuera del umbral para considerar que se desvió.
    var requiredConsecutiveFixes = 3
    /// Espera mínima entre dos recálculos automáticos.
    var cooldownSeconds: TimeInterval = 20
    /// Intentos automáticos fallidos seguidos antes de dejar de intentar hasta que el usuario
    /// vuelva al trayecto (o pida recalcular a mano).
    var maximumConsecutiveFailures = 3

    /// nil si la lectura no es lo bastante precisa para decidir. Cerca del destino nunca se
    /// está desviado: ahí decide la detección de llegada.
    func isOffRoute(_ fix: LocationFix, route: ActiveRoute) -> Bool? {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= maximumAccuracyMeters,
              fix.coordinate.isValid else { return nil }
        let toDestination = fix.coordinate.distance(to: route.destination.coordinate)
        guard toDestination > RouteProgressEstimator.arrivalRadiusMeters else { return false }
        return RouteProgressEstimator.distance(from: fix.coordinate, to: route) > offRouteThresholdMeters
    }
}

/// Qué pidió el recálculo. Decide qué se anuncia antes de calcular.
enum RerouteTrigger: Equatable {
    /// Primer intento tras desviarse: «Te saliste de la ruta. Recalculando.»
    case deviation
    /// Reintento automático tras un fallo: no repite el aviso ni el fallo.
    case retry
    /// Volvió la conexión y el usuario sigue desviado.
    case reconnected
    /// «Recalcular ruta» a mano.
    case manual
}

/// Resultado de un intento de recálculo.
enum RerouteOutcome: Equatable {
    /// Nueva ruta guardada (y sincronizada o pendiente).
    case rerouted(ActiveRoute)
    /// Sin red: se sigue con la copia local.
    case offline
    /// No se pudo calcular o guardar; la ruta anterior sigue activa.
    case failed(RouteCreationError)
    /// Mientras se calculaba, la ruta cambió (otro destino) o terminó: se descarta.
    case superseded
    case noActiveRoute
}

/// Qué pasa después de un recálculo fallido.
enum RerouteRetry: Equatable {
    /// Sigue desviado y quedan intentos automáticos.
    case automatic
    /// Sigue desviado pero se agotaron los intentos automáticos.
    case stopped
    /// No estaba desviado (se pidió a mano): no hay reintento automático.
    case none
}

/// Lo que la pantalla muestra del recálculo; usa los mismos textos que se locutan.
enum RerouteStatus: Equatable {
    case rerouting
    case rerouted(ActiveRoute)
    case waitingForConnection(destination: String)
    case failed(RouteCreationError, destination: String?, retry: RerouteRetry)

    var message: String {
        switch self {
        case .rerouting:
            return RerouteAnnouncements.inProgress
        case .rerouted(let route):
            return RerouteAnnouncements.rerouted(route)
        case .waitingForConnection(let destination):
            return RerouteAnnouncements.offline(destination: destination)
        case let .failed(error, destination, retry):
            let text = RerouteAnnouncements.failure(error, destination: destination)
            return retry == .stopped ? text + " " + RerouteAnnouncements.gaveUpHint : text
        }
    }
}

/// Textos de Recalcular Ruta. Se locutan y la pantalla muestra los mismos.
enum RerouteAnnouncements {
    static let deviated = "Te saliste de la ruta. Recalculando."
    static let manual = "Recalculando la ruta."
    static let reconnected = "Volvió la conexión. Recalculando la ruta."
    static let inProgress = "Recalculando la ruta…"
    static let noActiveRoute = "No hay una ruta activa para recalcular."
    /// Solo en pantalla, cuando ya no quedan intentos automáticos.
    static let gaveUpHint = "Vuelve al trayecto o usa «Recalcular ruta» para intentarlo de nuevo."

    static func rerouted(_ route: ActiveRoute) -> String {
        "Ruta recalculada hacia \(route.destination.name). " + RouteAnnouncements.summary(route)
    }

    static func offline(destination: String) -> String {
        "Sin conexión: no se puede recalcular la ruta. Sigue las indicaciones de tu ruta hacia "
            + "\(destination). Se recalculará cuando vuelva la conexión."
    }

    static func failure(_ error: RouteCreationError, destination: String?) -> String {
        guard let destination, error != .noActiveRoute else { return noActiveRoute }
        return "No se pudo recalcular la ruta. \(RouteAnnouncements.failure(error)) "
            + "Sigues con la ruta hacia \(destination)."
    }
}
