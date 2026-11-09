import Foundation

/// Resultado de Consultar Ruta Actual (SCRUM-23), siempre a partir de la copia local.
enum RouteStatus: Equatable {
    /// No hay ruta activa en este teléfono (SCRUM-138).
    case noActiveRoute
    /// La copia local existe pero no se pudo leer.
    case unreadable
    case active(ActiveRoute, RouteProgress)
}

/// Textos de Consultar Ruta. Se locutan y la pantalla muestra los mismos.
enum RouteStatusAnnouncements {
    static let noActiveRoute = "No tienes una ruta activa. Indica un destino para crear una."
    static let unreadable = "No se pudo leer la ruta guardada en este teléfono. "
        + "Indica el destino de nuevo para crear una ruta."
    static let approximateNote = "No se pudo obtener tu ubicación, así que el avance es aproximado."

    /// Por debajo de este porcentaje se dice que se está al inicio, no «el 2 por ciento».
    static let startPercent = 5
    /// Más cerca que esto, la siguiente indicación se da sin distancia.
    static let immediateManeuverMeters = 10.0

    static func text(
        for status: RouteStatus, instructions: NavigationInstructionBuilder = NavigationInstructionBuilder()
    ) -> String {
        switch status {
        case .noActiveRoute:
            return noActiveRoute
        case .unreadable:
            return unreadable
        case let .active(route, progress):
            var parts = [destinationSentence(route)]
            if progress.isArriving {
                parts.append(progressSentence(progress))
                if let step = progress.nextStep { parts.append("\(step.instruction).") }
                return parts.joined(separator: " ")
            }
            if progress.basis == .storedStep { parts.append(approximateNote) }
            parts.append(progressSentence(progress))
            parts.append(nextSentence(progress, in: route, instructions: instructions))
            return parts.joined(separator: " ")
        }
    }

    /// Destino actual (SCRUM-140).
    static func destinationSentence(_ route: ActiveRoute) -> String {
        "Vas hacia \(route.destination.name)."
    }

    /// Avance y lo que falta (SCRUM-139).
    static func progressSentence(_ progress: RouteProgress) -> String {
        if progress.isArriving {
            let radius = SpokenDistance.text(meters: RouteProgressEstimator.arrivalRadiusMeters)
            return "Estás llegando: el destino está a menos de \(radius)."
        }
        var remaining = "te faltan \(SpokenDistance.text(meters: progress.distanceRemainingMeters))"
        if let time = SpokenDuration.approximate(seconds: progress.remainingTimeSeconds) {
            remaining += ", \(time) caminando"
        }
        if progress.percent < startPercent {
            return "Estás al inicio del recorrido: \(remaining)."
        }
        return "Has recorrido el \(progress.percent) por ciento: \(remaining)."
    }

    /// Siguiente indicación de navegación.
    static func nextSentence(
        _ progress: RouteProgress, in route: ActiveRoute,
        instructions: NavigationInstructionBuilder = NavigationInstructionBuilder()
    ) -> String {
        guard let step = progress.nextStep else {
            return "Lo siguiente es llegar a \(route.destination.name)."
        }
        guard let distance = progress.distanceToNextMeters else {
            // Sin ubicación no se sabe cuánto falta para la maniobra: se da el paso completo.
            return "Siguiente indicación: \(instructions.spokenText(for: step))"
        }
        if distance < immediateManeuverMeters {
            return "Siguiente indicación: \(step.instruction)."
        }
        return "Siguiente indicación en \(SpokenDistance.text(meters: distance)): \(step.instruction)."
    }
}
