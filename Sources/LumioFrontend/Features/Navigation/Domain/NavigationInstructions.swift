import Foundation

/// Distancias para locutar: redondeadas como las diría una persona.
enum SpokenDistance {
    static func text(meters: Double) -> String {
        let meters = max(0, meters)
        if meters < 1000 {
            let value = meters < 100 ? Int(meters.rounded()) : Int((meters / 10).rounded()) * 10
            if value < 1000 {
                return value == 1 ? "1 metro" : "\(value) metros"
            }
        }
        let tenths = Int((meters / 100).rounded())
        let whole = tenths / 10
        let decimal = tenths % 10
        if decimal == 0 {
            return whole == 1 ? "1 kilómetro" : "\(whole) kilómetros"
        }
        return "\(whole),\(decimal) kilómetros"
    }
}

enum SpokenDuration {
    /// nil si no hay estimación.
    static func text(seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 {
            return minutes == 1 ? "1 minuto" : "\(minutes) minutos"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        let hoursText = hours == 1 ? "1 hora" : "\(hours) horas"
        guard rest > 0 else { return hoursText }
        return "\(hoursText) y \(rest == 1 ? "1 minuto" : "\(rest) minutos")"
    }
}

/// Textos que se locutan en Crear Ruta. La pantalla muestra los mismos.
enum RouteAnnouncements {
    static func ready(_ route: ActiveRoute) -> String {
        var text = "Ruta lista hacia \(route.destination.name). "
            + "Son \(SpokenDistance.text(meters: route.distanceMeters))"
        if let duration = SpokenDuration.text(seconds: route.expectedTravelTimeSeconds) {
            text += ", unos \(duration) caminando"
        }
        return text + "."
    }

    static func failure(_ error: RouteCreationError) -> String {
        switch error {
        case .emptyDestination:
            return "No se indicó un destino. Di o escribe a dónde quieres ir."
        case .locationPermissionDenied:
            return "Lumio no tiene permiso para usar tu ubicación. "
                + "Actívalo en Ajustes, Privacidad, Localización."
        case .locationUnavailable:
            return "No se pudo obtener tu ubicación actual con precisión. "
                + "Intenta de nuevo en un momento."
        case .destinationNotFound:
            return "No se encontró el destino indicado. Intenta con otra dirección o lugar."
        case .noRouteAvailable:
            return "No hay una ruta peatonal disponible hacia ese destino."
        case .localStorageFailed:
            return "No se pudo guardar la ruta en el dispositivo. Intenta de nuevo."
        case .serviceUnavailable:
            return "No se pudo calcular la ruta en este momento. "
                + "Revisa tu conexión e intenta de nuevo."
        }
    }
}

/// Genera las instrucciones paso a paso y sus mensajes de navegación (prioridad 2).
struct NavigationInstructionBuilder {
    static let failureContextID = "route-creation"

    static func contextID(for routeID: UUID) -> String {
        "route-\(routeID.uuidString)"
    }

    /// Normaliza los pasos del proveedor: descarta los que no tienen instrucción (MapKit
    /// devuelve un paso inicial vacío) y numera los restantes desde 0.
    func steps(from calculated: [CalculatedRouteStep]) -> [RouteStep] {
        calculated
            .compactMap { step -> (String, CalculatedRouteStep)? in
                normalized(step.instruction).map { ($0, step) }
            }
            .enumerated()
            .map { order, item in
                RouteStep(
                    order: order,
                    instruction: item.0,
                    distanceMeters: max(0, item.1.distanceMeters),
                    maneuverCoordinate: item.1.maneuverCoordinate.flatMap { $0.isValid ? $0 : nil }
                )
            }
    }

    func spokenText(for step: RouteStep) -> String {
        guard step.distanceMeters >= 1 else { return "\(step.instruction)." }
        return "\(step.instruction) y continúa \(SpokenDistance.text(meters: step.distanceMeters))."
    }

    func message(for step: RouteStep, routeID: UUID, now: Date) -> AudioMessage {
        AudioMessage(
            text: spokenText(for: step),
            priority: .routeInformation,
            createdAt: now,
            contextID: Self.contextID(for: routeID),
            deduplicationKey: "step-\(step.order)"
        )
    }

    func readyMessage(for route: ActiveRoute, now: Date) -> AudioMessage {
        AudioMessage(
            text: RouteAnnouncements.ready(route),
            priority: .routeInformation,
            createdAt: now,
            contextID: Self.contextID(for: route.id),
            deduplicationKey: "route-ready"
        )
    }

    func failureMessage(_ error: RouteCreationError, now: Date) -> AudioMessage {
        AudioMessage(
            text: RouteAnnouncements.failure(error),
            priority: .routeInformation,
            createdAt: now,
            contextID: Self.failureContextID,
            deduplicationKey: "failure-\(error)"
        )
    }

    private func normalized(_ instruction: String) -> String? {
        let words = instruction.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        var text = words.joined(separator: " ")
        while text.hasSuffix(".") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
