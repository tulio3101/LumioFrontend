#if canImport(SwiftUI)
import SwiftUI

struct DestinationView: View {
    @StateObject private var model: DestinationViewModel

    #if os(iOS)
    @ObservedObject var permissions: PermissionsViewModel

    init(service: any NavigationPlanning, permissions: PermissionsViewModel) {
        _model = StateObject(wrappedValue: DestinationViewModel(service: service))
        self.permissions = permissions
    }
    #else
    init(service: any NavigationPlanning) {
        _model = StateObject(wrappedValue: DestinationViewModel(service: service))
    }

    #endif

    var body: some View {
        Form {
            #if os(iOS)
            Section {
                NavigationLink("Preparar permisos") { PermissionsView(model: permissions) }
                if !permissions.message.isEmpty { Text(permissions.message) }
            }
            #endif
            Section("Destino") {
                TextField("Dirección o lugar", text: $model.destination)
                    .disabled(model.isLoading)
                Button("Calcular ruta") {
                    Task {
                        #if os(iOS)
                        guard await permissions.reportRequirements(.route) else { return }
                        #endif
                        await model.planRoute()
                    }
                }
                .disabled(!model.canPlan)
                if model.isLoading {
                    ProgressView("Calculando ruta")
                }
            }
            if let error = model.errorMessage {
                Section {
                    FeatureStatusView(title: "No se calculó la ruta", message: error)
                }
            }
            if let route = model.route {
                Section("Ruta calculada") {
                    Text(route.destination)
                }
            }
            Section {
                FeatureStatusView(
                    title: "Asistencia aún no disponible",
                    message: "La detección de obstáculos y la navegación asistida están pendientes de integración."
                )
            }
        }
        .navigationTitle("Lumio")
    }
}
#endif
