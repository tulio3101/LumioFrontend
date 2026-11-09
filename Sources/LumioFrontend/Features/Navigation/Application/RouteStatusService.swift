import Foundation

/// Consultar Ruta Actual (SCRUM-23): destino, avance y siguiente indicación de la ruta activa.
///
/// - La ruta sale de la copia local; no se consulta el backend, así que funciona sin conexión.
/// - El avance se estima con una lectura de GPS nueva (no necesita internet). Si no hay
///   ubicación, se usa el último paso registrado y se avisa de que es aproximado.
/// - La respuesta se locuta siempre por el AudioArbiter, también cuando no hay ruta.
/// - No guarda nada: avanzar el paso durante el trayecto es de Guiar Giros (SCRUM-312).
@MainActor
final class RouteStatusService: RouteStatusQuerying {
    private let store: any ActiveRouteStoring
    private let location: any CurrentLocationProviding
    private let arbiter: any AudioArbitrating
    private let estimator: RouteProgressEstimator
    private let instructions: NavigationInstructionBuilder
    private let now: () -> Date

    init(
        store: any ActiveRouteStoring,
        location: any CurrentLocationProviding,
        arbiter: any AudioArbitrating,
        estimator: RouteProgressEstimator = RouteProgressEstimator(),
        instructions: NavigationInstructionBuilder = NavigationInstructionBuilder(),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.location = location
        self.arbiter = arbiter
        self.estimator = estimator
        self.instructions = instructions
        self.now = now
    }

    func queryActiveRoute() async -> RouteStatus {
        let status: RouteStatus
        do {
            if let route = try store.load() {
                // Sin permiso o sin precisión, el avance se calcula con el paso guardado.
                let position = try? await location.currentLocation()
                status = .active(route, estimator.progress(of: route, at: position))
            } else {
                status = .noActiveRoute
            }
        } catch {
            status = .unreadable
        }
        arbiter.receive(instructions.statusMessage(status, now: now()))
        return status
    }
}
