#if canImport(SwiftUI)
import SwiftUI

/// Detalle de la ruta activa: resumen, estado de guardado e indicaciones paso a paso.
struct ActiveRouteView: View {
    @ObservedObject var model: DestinationViewModel

    @State private var isChangingDestination = false
    @AccessibilityFocusState private var summaryHasFocus: Bool

    var body: some View {
        Group {
            if let route = model.route {
                content(route)
            } else {
                Text("No hay una ruta activa.")
                    .foregroundStyle(LumioColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LumioColor.background.ignoresSafeArea())
        .navigationTitle("Tu ruta")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .sheet(isPresented: $isChangingDestination) {
            RoutePlannerView(model: model, mode: .changeDestination) {
                isChangingDestination = false
                focusSummary()
            }
        }
        .onAppear(perform: focusSummary)
    }

    private func content(_ route: ActiveRoute) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.updatedRevision == route.revision {
                    LumioStatusBanner(
                        .success,
                        title: "Ruta actualizada",
                        message: "Estas son las nuevas indicaciones desde donde estabas al cambiar el destino."
                    )
                }
                RouteSummaryCard(route: route, headerFocus: $summaryHasFocus)
                if route.isPendingBackendSync {
                    LumioStatusBanner(
                        .warning,
                        title: "Guardada solo en este teléfono",
                        message: "Puedes seguirla sin problema. Se guardará en el servidor la próxima vez que abras Lumio con conexión."
                    )
                }
                stepsSection(route)
                Button {
                    isChangingDestination = true
                } label: {
                    Label("Cambiar destino", systemImage: "arrow.triangle.swap")
                }
                .buttonStyle(LumioSecondaryButtonStyle())
                .accessibilityHint("Calcula una ruta nueva desde donde estás. La actual sigue activa hasta que la nueva esté lista.")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private func stepsSection(_ route: ActiveRoute) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Paso a paso")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(LumioColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(route.steps.count == 1 ? "1 indicación" : "\(route.steps.count) indicaciones")
                    .font(.subheadline)
                    .foregroundStyle(LumioColor.textSecondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(route.steps, id: \.order) { step in
                    RouteStepRow(
                        step: step,
                        total: route.steps.count,
                        isCurrent: step.order == route.currentStep,
                        spokenText: model.spokenText(for: step)
                    )
                }
                ArrivalRow(destination: route.destination.name)
            }
            .lumioCard(padding: 18)
        }
    }

    /// Al llegar (o al cambiar de ruta) VoiceOver empieza por el resumen, no por la barra.
    private func focusSummary() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { summaryHasFocus = true }
    }
}

// MARK: Componentes de ruta

/// Destino, distancia, duración y estado de guardado. También se usa en el inicio.
struct RouteSummaryCard: View {
    let route: ActiveRoute
    /// Permite llevar el foco de VoiceOver al encabezado (destino) de la tarjeta.
    var headerFocus: AccessibilityFocusState<Bool>.Binding?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                LumioIconBadge(systemName: "figure.walk", size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ruta a pie hacia")
                        .font(.subheadline)
                        .foregroundStyle(LumioColor.textSecondary)
                    Text(route.destination.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(LumioColor.textPrimary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .modifier(OptionalAccessibilityFocus(binding: headerFocus))

            Rectangle()
                .fill(LumioColor.controlBorder.opacity(0.3))
                .frame(height: 1)
                .accessibilityHidden(true)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) { metrics }
                VStack(alignment: .leading, spacing: 14) { metrics }
            }

            if !route.isPendingBackendSync {
                Label("Guardada en el servidor", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LumioColor.successText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(LumioColor.successBackground, in: Capsule())
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .lumioCard()
    }

    @ViewBuilder
    private var metrics: some View {
        RouteMetric(
            title: "Distancia",
            value: SpokenDistance.text(meters: route.distanceMeters),
            systemImage: "point.topleft.down.curvedto.point.bottomright.up"
        )
        RouteMetric(
            title: "Caminando",
            value: SpokenDuration.approximate(seconds: route.expectedTravelTimeSeconds)
                .map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Sin estimación",
            systemImage: "clock"
        )
        RouteMetric(
            title: "Desde",
            value: route.origin.name,
            systemImage: "location"
        )
    }
}

private struct OptionalAccessibilityFocus: ViewModifier {
    let binding: AccessibilityFocusState<Bool>.Binding?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let binding {
            content.accessibilityFocused(binding)
        } else {
            content
        }
    }
}

private struct RouteMetric: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LumioColor.textSecondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(LumioColor.textPrimary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

/// Un paso como nodo de una línea de tiempo. El paso actual se marca con texto, no solo color.
private struct RouteStepRow: View {
    let step: RouteStep
    let total: Int
    let isCurrent: Bool
    let spokenText: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                Text("\(step.order + 1)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isCurrent ? LumioColor.onActionPrimary : LumioColor.actionPrimary)
                    .frame(width: 34, height: 34)
                    .background {
                        Circle().fill(isCurrent ? LumioColor.actionPrimary : LumioColor.surface)
                    }
                    .overlay {
                        Circle().strokeBorder(LumioColor.actionPrimary, lineWidth: isCurrent ? 0 : 1.5)
                    }
                Rectangle()
                    .fill(LumioColor.controlBorder.opacity(0.45))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 6) {
                if isCurrent {
                    Text("Siguiente")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(LumioColor.actionPrimary)
                }
                Text(step.instruction)
                    .font(isCurrent ? .body.weight(.semibold) : .body)
                    .foregroundStyle(LumioColor.textPrimary)
                if step.distanceMeters >= 1 {
                    Label(
                        "Continúa \(SpokenDistance.text(meters: step.distanceMeters))",
                        systemImage: "arrow.up"
                    )
                    .font(.subheadline)
                    .foregroundStyle(LumioColor.textSecondary)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let position = "Paso \(step.order + 1) de \(total)"
        return isCurrent ? "\(position), siguiente: \(spokenText)" : "\(position): \(spokenText)"
    }
}

private struct ArrivalRow: View {
    let destination: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "flag.checkered")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(LumioColor.successText)
                .frame(width: 34, height: 34)
                .background(LumioColor.successBackground, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Llegada")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(LumioColor.textSecondary)
                Text(destination)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(LumioColor.textPrimary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Llegada a \(destination)")
    }
}
#endif
