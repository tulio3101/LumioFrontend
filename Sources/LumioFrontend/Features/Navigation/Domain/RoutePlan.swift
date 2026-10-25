import Foundation

struct RoutePlan: Identifiable, Equatable {
    let id: UUID
    let destination: String
    let instructions: [String]
}

protocol NavigationPlanning {
    func planRoute(to destination: String) async throws -> RoutePlan
}
