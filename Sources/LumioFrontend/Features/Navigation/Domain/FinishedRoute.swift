import Foundation

/// Ruta finalizada en el teléfono: la última versión de la ruta, cómo terminó y cuándo.
/// Se guarda en la cola hasta que llega al historial del backend.
struct FinishedRoute: Codable, Equatable {
    let route: ActiveRoute
    let outcome: RouteHistoryEntry.Outcome
    let finishedAt: Date
}

/// Quién finalizó la ruta.
enum RouteFinishTrigger: Equatable {
    /// El usuario con «Finalizar ruta».
    case manual
    /// Lumio al detectar la llegada al destino.
    case arrival
}

struct RouteFinishResult: Equatable {
    let finished: FinishedRoute
    let trigger: RouteFinishTrigger
}

/// Cuándo se considera que el usuario llegó (SCRUM-127).
struct ArrivalPolicy {
    /// Mismo radio que «Estás llegando» en Consultar Ruta.
    var radiusMeters = RouteProgressEstimator.arrivalRadiusMeters
    /// Lecturas menos precisas no cuentan: un salto del GPS no finaliza la ruta.
    var maximumAccuracyMeters = 20.0
    /// Lecturas precisas seguidas dentro del radio.
    var requiredConsecutiveFixes = 2

    /// nil si la lectura no es lo bastante precisa para decidir.
    func isNearDestination(_ fix: LocationFix, destination: RoutePlace) -> Bool? {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= maximumAccuracyMeters,
              fix.coordinate.isValid else { return nil }
        return fix.coordinate.distance(to: destination.coordinate) <= radiusMeters
    }
}

/// Textos de Finalizar Ruta. Se locutan y la pantalla muestra los mismos.
enum RouteFinishAnnouncements {
    static let noActiveRoute = "No hay una ruta activa para finalizar."
    static let historyNote = "La ruta se guarda en tu historial. Si no hay conexión, "
        + "se guardará cuando vuelva."

    static func finished(_ result: RouteFinishResult) -> String {
        let destination = result.finished.route.destination.name
        switch (result.trigger, result.finished.outcome) {
        case (.arrival, _):
            return "Llegaste a \(destination). La navegación terminó."
        case (.manual, .completed):
            return "Navegación finalizada. Llegaste a \(destination)."
        case (.manual, .cancelled):
            return "Navegación finalizada. La ruta hacia \(destination) quedó sin terminar."
        }
    }

    /// Título de la pantalla final.
    static func title(_ result: RouteFinishResult) -> String {
        result.finished.outcome == .completed
            ? "Llegaste a \(result.finished.route.destination.name)"
            : "Ruta finalizada"
    }
}
