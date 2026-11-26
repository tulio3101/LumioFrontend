import Foundation

/// Ruta del historial del backend: ya no está abierta (completada o cancelada al iniciar otra).
struct RouteHistoryEntry: Equatable {
    enum Outcome: String, Codable, Equatable {
        case completed
        case cancelled
    }

    let destination: RoutePlace
    let outcome: Outcome
    let startedAt: Date
    let finishedAt: Date?

    /// Cuándo se usó por última vez: al terminar o, si no consta, al empezar.
    var lastUsedAt: Date { finishedAt ?? startedAt }
}

/// Destino del historial agrupado: una entrada por lugar con la vez más reciente que se usó.
struct RecentDestination: Codable, Equatable, Identifiable {
    let place: RoutePlace
    let lastUsedAt: Date
    let lastOutcome: RouteHistoryEntry.Outcome
    let timesUsed: Int

    var id: String { "\(place.name)\n\(place.coordinate.latitude),\(place.coordinate.longitude)" }
}

/// Resultado de Consultar Rutas Recientes (SCRUM-24).
struct RecentRoutes: Equatable {
    enum Source: Equatable {
        case backend
        /// Sin conexión: la última lista recibida, guardada en el teléfono.
        case savedCopy(savedAt: Date)
    }

    let destinations: [RecentDestination]
    let source: Source
}

/// Copia en el teléfono de la última lista de destinos recientes.
struct SavedRecentRoutes: Codable, Equatable {
    let destinations: [RecentDestination]
    let savedAt: Date
}

enum RecentRoutesError: Error, Equatable {
    /// El backend no respondió y no hay copia guardada.
    case unavailable
}

/// Cómo se agrupan y se muestran los destinos recientes.
enum RecentRoutesPolicy {
    /// Mismo nombre a esta distancia o menos: es el mismo lugar.
    static let sameDestinationMeters = 25.0
    /// Rutas que se piden al backend; agrupadas suelen quedar menos destinos.
    static let fetchLimit = 50
    /// En la hoja de destino: pocas opciones, rápidas de recorrer con VoiceOver.
    static let plannerLimit = 5

    /// Agrupa por lugar, de la más reciente a la más antigua.
    static func grouped(_ entries: [RouteHistoryEntry]) -> [RecentDestination] {
        var groups: [RecentDestination] = []
        for entry in entries.sorted(by: { $0.lastUsedAt > $1.lastUsedAt }) {
            if let index = groups.firstIndex(where: { isSamePlace($0.place, entry.destination) }) {
                let group = groups[index]
                groups[index] = RecentDestination(
                    place: group.place, lastUsedAt: group.lastUsedAt,
                    lastOutcome: group.lastOutcome, timesUsed: group.timesUsed + 1
                )
            } else {
                groups.append(RecentDestination(
                    place: entry.destination, lastUsedAt: entry.lastUsedAt,
                    lastOutcome: entry.outcome, timesUsed: 1
                ))
            }
        }
        return groups
    }

    /// Mismo nombre (sin distinguir mayúsculas ni tildes) y a menos de 25 m.
    static func isSamePlace(_ first: RoutePlace, _ second: RoutePlace) -> Bool {
        normalizedName(first.name) == normalizedName(second.name)
            && first.coordinate.distance(to: second.coordinate) <= sameDestinationMeters
    }

    /// Para la hoja de destino: sin el destino actual (ir a donde ya vas no cambia nada).
    static func plannerDestinations(
        _ destinations: [RecentDestination], excluding current: RoutePlace?
    ) -> [RecentDestination] {
        Array(
            destinations
                .filter { destination in current.map { !isSamePlace(destination.place, $0) } ?? true }
                .prefix(plannerLimit)
        )
    }

    private static func normalizedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Textos de Consultar Rutas Recientes. Se locutan y la pantalla muestra los mismos.
enum RecentRoutesAnnouncements {
    static let empty = "No tienes rutas recientes. Cuando uses una ruta, su destino aparecerá aquí."
    static let unavailable = "No se pudieron cargar tus rutas recientes. Revisa tu conexión e intenta de nuevo."
    static let savedCopyNote = "Sin conexión: es la última lista guardada en este teléfono."

    /// Corto a propósito: el detalle se recorre en la lista y el audio no debe retrasar la
    /// ruta si se elige un destino enseguida.
    static func text(for routes: RecentRoutes) -> String {
        let summary: String
        switch routes.destinations.count {
        case 0:
            summary = empty
        case 1:
            summary = "Tienes 1 destino reciente: \(routes.destinations[0].place.name)."
        default:
            summary = "Tienes \(routes.destinations.count) destinos recientes. "
                + "El más reciente es \(routes.destinations[0].place.name)."
        }
        if case .savedCopy = routes.source {
            return "\(savedCopyNote) \(summary)"
        }
        return summary
    }

    static func outcome(_ outcome: RouteHistoryEntry.Outcome) -> String {
        switch outcome {
        case .completed: return "Completada"
        case .cancelled: return "Sin terminar"
        }
    }

    static func timesUsed(_ count: Int) -> String? {
        count > 1 ? "\(count) veces" : nil
    }

    /// «hace un momento», «hace 5 minutos», «hace 2 horas», «ayer», «hace 3 días» o la fecha.
    static func lastUsed(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "hace un momento" }
        if minutes < 60 { return minutes == 1 ? "hace 1 minuto" : "hace \(minutes) minutos" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "hace 1 hora" : "hace \(hours) horas" }
        let days = hours / 24
        if days == 1 { return "ayer" }
        if days < 7 { return "hace \(days) días" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "d 'de' MMMM"
            : "d 'de' MMMM 'de' y"
        return "el \(formatter.string(from: date))"
    }
}
