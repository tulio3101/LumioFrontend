#if canImport(SwiftUI)
import SwiftUI

@MainActor
final class DestinationViewModel: ObservableObject {
    @Published var destination = ""
    @Published private(set) var isLoading = false
    @Published private(set) var route: RoutePlan?
    @Published private(set) var errorMessage: String?

    private let service: any NavigationPlanning

    init(service: any NavigationPlanning) {
        self.service = service
    }

    var canPlan: Bool {
        !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    func planRoute() async {
        guard canPlan else { return }
        isLoading = true
        route = nil
        errorMessage = nil
        defer { isLoading = false }
        do {
            route = try await service.planRoute(
                to: destination.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch FeatureUnavailable.navigation {
            errorMessage = "La planificación de rutas todavía no está conectada."
        } catch {
            errorMessage = "No se pudo calcular la ruta. Intenta nuevamente."
        }
    }
}
#endif
