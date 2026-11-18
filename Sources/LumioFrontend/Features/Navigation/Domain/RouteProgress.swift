import Foundation

/// Avance del trayecto en el momento de la consulta (Consultar Ruta, SCRUM-139). No se
/// guarda: avanzar el paso de la ruta mientras se camina es trabajo de Guiar Giros
/// (SCRUM-312).
struct RouteProgress: Equatable {
    enum Basis: Equatable {
        /// Estimado con una lectura de GPS sobre los puntos de maniobra de la ruta.
        case location
        /// Sin ubicación: según el último paso registrado en la copia local.
        case storedStep
    }

    let basis: Basis
    /// Indicación que viene; nil si solo queda llegar al destino.
    let nextStep: RouteStep?
    /// Metros hasta donde empieza `nextStep` (o hasta el destino). nil sin ubicación.
    let distanceToNextMeters: Double?
    let distanceCoveredMeters: Double
    let distanceRemainingMeters: Double
    let remainingTimeSeconds: Double
    /// A menos de `RouteProgressEstimator.arrivalRadiusMeters` del destino.
    let isArriving: Bool
    /// Parte recorrida, de 0 a 1.
    let fraction: Double

    var percent: Int { Int((fraction * 100).rounded()) }
}

/// Estima el avance proyectando la posición sobre la ruta.
///
/// La ruta se aproxima con tramos rectos: origen → punto de cada maniobra → destino (cada
/// paso de MapKit empieza en su maniobra y recorre `distanceMeters`). El tramo más cercano
/// a la posición dice qué maniobra viene; lo que falta es lo que queda de ese tramo más
/// las distancias de los pasos siguientes.
struct RouteProgressEstimator {
    /// A esta distancia del destino se considera que se está llegando.
    static let arrivalRadiusMeters = 25.0

    func progress(of route: ActiveRoute, at position: GeoCoordinate?) -> RouteProgress {
        guard let position, position.isValid else { return fromStoredStep(route) }

        let toDestination = position.distance(to: route.destination.coordinate)
        if toDestination <= Self.arrivalRadiusMeters {
            return make(
                route, basis: .location, next: route.steps.last,
                toNext: toDestination, remaining: toDestination, isArriving: true
            )
        }

        let nodes = Self.nodes(of: route)
        var nearest = (segment: 0, offset: Double.infinity, toEnd: 0.0)
        for index in 0..<(nodes.count - 1) {
            let projection = Self.project(position, from: nodes[index].coordinate, to: nodes[index + 1].coordinate)
            // Con empate gana el tramo anterior: la maniobra donde estás aún no se ha hecho.
            if projection.offset < nearest.offset {
                nearest = (index, projection.offset, projection.toEnd)
            }
        }
        let end = nodes[nearest.segment + 1]
        let afterEnd = end.stepIndex.map { Self.length(of: route.steps[$0...]) } ?? 0
        return make(
            route, basis: .location, next: end.stepIndex.map { route.steps[$0] },
            toNext: nearest.toEnd, remaining: nearest.toEnd + afterEnd, isArriving: false
        )
    }

    /// Metros de `position` al tramo más cercano de la ruta, con la misma aproximación de
    /// tramos rectos. Recalcular Ruta (SCRUM-26) lo compara con su umbral de desviación.
    static func distance(from position: GeoCoordinate, to route: ActiveRoute) -> Double {
        let nodes = nodes(of: route)
        var nearest = Double.infinity
        for index in 0..<(nodes.count - 1) {
            nearest = min(nearest, project(position, from: nodes[index].coordinate, to: nodes[index + 1].coordinate).offset)
        }
        return nearest
    }

    // MARK: Sin ubicación

    /// Lo recorrido hasta el paso guardado. En el primer paso se cuenta como el inicio.
    private func fromStoredStep(_ route: ActiveRoute) -> RouteProgress {
        let total = max(0, route.distanceMeters)
        let current = min(max(0, route.currentStep), route.steps.count)
        let beforeFirstManeuver = max(0, total - Self.length(of: route.steps[...]))
        let covered = current == 0
            ? 0
            : min(total, beforeFirstManeuver + Self.length(of: route.steps[..<current]))
        return make(
            route, basis: .storedStep, next: route.currentInstruction,
            toNext: nil, remaining: total - covered, isArriving: false
        )
    }

    // MARK: Apoyo

    private func make(
        _ route: ActiveRoute, basis: RouteProgress.Basis, next: RouteStep?,
        toNext: Double?, remaining: Double, isArriving: Bool
    ) -> RouteProgress {
        let total = max(0, route.distanceMeters)
        let remaining = max(0, remaining)
        let covered = min(total, max(0, total - remaining))
        let fraction = total > 0 ? covered / total : (isArriving ? 1 : 0)
        let time = total > 0 ? max(0, route.expectedTravelTimeSeconds) * remaining / total : 0
        return RouteProgress(
            basis: basis,
            nextStep: next,
            distanceToNextMeters: toNext.map { max(0, $0) },
            distanceCoveredMeters: covered,
            distanceRemainingMeters: remaining,
            remainingTimeSeconds: time,
            isArriving: isArriving,
            fraction: fraction
        )
    }

    private struct Node {
        let coordinate: GeoCoordinate
        /// Paso que empieza en este punto; nil para el origen (y el destino sin paso).
        let stepIndex: Int?
    }

    /// Origen, maniobras con punto conocido y destino. Si el último paso (la llegada) no
    /// trae punto, se asocia al destino.
    private static func nodes(of route: ActiveRoute) -> [Node] {
        var nodes = [Node(coordinate: route.origin.coordinate, stepIndex: nil)]
        for (index, step) in route.steps.enumerated() {
            if let coordinate = step.maneuverCoordinate {
                nodes.append(Node(coordinate: coordinate, stepIndex: index))
            }
        }
        let arrival = route.steps.last?.maneuverCoordinate == nil && !route.steps.isEmpty
            ? route.steps.count - 1
            : nil
        nodes.append(Node(coordinate: route.destination.coordinate, stepIndex: arrival))
        return nodes
    }

    private static func length(of steps: ArraySlice<RouteStep>) -> Double {
        steps.reduce(0) { $0 + max(0, $1.distanceMeters) }
    }

    /// Distancia de `point` al tramo y lo que queda del tramo desde su proyección. Usa un
    /// plano local alrededor del inicio del tramo: suficiente para distancias a pie.
    private static func project(
        _ point: GeoCoordinate, from start: GeoCoordinate, to end: GeoCoordinate
    ) -> (offset: Double, toEnd: Double) {
        let metersPerDegree = 6_371_000 * Double.pi / 180
        let cosLatitude = cos(start.latitude * .pi / 180)
        func local(_ coordinate: GeoCoordinate) -> (x: Double, y: Double) {
            (
                (coordinate.longitude - start.longitude) * metersPerDegree * cosLatitude,
                (coordinate.latitude - start.latitude) * metersPerDegree
            )
        }
        let e = local(end)
        let p = local(point)
        let lengthSquared = e.x * e.x + e.y * e.y
        let t = lengthSquared > 0 ? min(1, max(0, (p.x * e.x + p.y * e.y) / lengthSquared)) : 0
        let offset = hypot(p.x - t * e.x, p.y - t * e.y)
        return (offset, (1 - t) * lengthSquared.squareRoot())
    }
}
