import Foundation

/// SCRUM-41: disponibilidad de la narración del entorno. SCRUM-38/39 leen este estado; la
/// detección y la navegación no dependen de él.
enum NarrationAvailability: Equatable {
    case available
    case unavailable
    case checking
}

@MainActor
protocol NarrationAvailabilityObserving: AnyObject {
    var availability: NarrationAvailability { get }
    /// false si no hay narración: la solicitud se descarta y se avisa (P3).
    func allowRequest() -> Bool
}

/// Comprueba si el backend (LumioAPIBaseURL) responde. Un código HTTP cuenta como alcanzable.
protocol EndpointHealthChecking: AnyObject {
    func isReachable() async -> Bool
}
