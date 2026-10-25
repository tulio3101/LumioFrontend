#if canImport(SwiftUI)
import SwiftUI

struct DestinationView: View {
    @StateObject private var model: DestinationViewModel

    init(service: any NavigationPlanning) {
        _model = StateObject(wrappedValue: DestinationViewModel(service: service))
    }

    var body: some View {
        Form {
            Section("Destino") {
                TextField("Dirección o lugar", text: $model.destination)
                    .disabled(model.isLoading)
                Button("Calcular ruta") {
                    Task { await model.planRoute() }
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
                    message: "La cámara, las alertas y la reproducción de audio están pendientes de integración."
                )
            }
        }
        .navigationTitle("Lumio")
    }
}
#endif
