import Foundation

struct SafetyEvent: Identifiable {
    let id: UUID
    let description: String
    let detectedAt: Date
    let requiresImmediateAction: Bool
}

/// Implementar con cámara/Core ML y profundidad local; nunca depende del backend.
@MainActor
protocol SafetyMonitoring: AnyObject {
    var onEvent: ((SafetyEvent) -> Void)? { get set }
    func start() async throws
    func stop()
}
