#if canImport(SwiftUI)
import SwiftUI

struct DestinationView: View {
    @StateObject private var model: DestinationViewModel
    #if os(iOS) && DEBUG
    @EnvironmentObject var debugContainer: DebugSafetyContainer
    #endif

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
                #if os(iOS) && DEBUG
                if let service = debugContainer.service {
                    DebugSafetySection(service: service)
                } else {
                    FeatureStatusView(
                        title: "SafetyService no disponible",
                        message: "Falta yolo26n_640_int8.mlpackage en Copy Bundle Resources del target lumio."
                    )
                }
                #else
                FeatureStatusView(
                    title: "Asistencia aún no disponible",
                    message: "La cámara, las alertas y la reproducción de audio están pendientes de integración."
                )
                #endif
            }
        }
        .navigationTitle("Lumio")
    }
}
#endif
