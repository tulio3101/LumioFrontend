#if canImport(SwiftUI)
import SwiftUI

/// Inicio del trayecto. Una sola acción principal: sin ruta, «Indicar destino»; con ruta
/// activa, «Ver indicaciones» (y «Cambiar destino» como secundaria). Planificar o cambiar el
/// destino ocurre en su propia hoja (RoutePlannerView) y el detalle de la ruta en su propia
/// pantalla (ActiveRouteView).
struct DestinationView: View {
    @StateObject private var model: DestinationViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var planning: DestinationViewModel.PlanningMode?
    @State private var showsRoute = false
    /// La hoja se cierra antes de navegar para que ambas transiciones no se mezclen.
    @State private var opensRouteAfterPlanning = false
    @State private var hasAppeared = false

    init(
        routeCreator: any RouteCreating,
        routeModifier: (any RouteModifying)? = nil,
        instructionRepeater: (any InstructionRepeating)? = nil,
        suggester: (any DestinationSuggesting)? = nil
    ) {
        _model = StateObject(wrappedValue: DestinationViewModel(
            routeCreator: routeCreator,
            routeModifier: routeModifier,
            instructionRepeater: instructionRepeater,
            suggester: suggester
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                brandBar
                    .lumioEntrance(hasAppeared, delay: 0, reduceMotion: reduceMotion)
                if let route = model.route {
                    activeRouteSection(route)
                        .lumioEntrance(hasAppeared, delay: 0.1, reduceMotion: reduceMotion)
                } else {
                    emptyState
                        .lumioEntrance(hasAppeared, delay: 0.1, reduceMotion: reduceMotion)
                    howItWorks
                        .lumioEntrance(hasAppeared, delay: 0.2, reduceMotion: reduceMotion)
                }
                upcomingFeatures
                    .lumioEntrance(hasAppeared, delay: 0.3, reduceMotion: reduceMotion)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(LumioColor.background.ignoresSafeArea())
        .navigationTitle("Trayecto")
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .navigationDestination(isPresented: $showsRoute) {
            ActiveRouteView(model: model)
        }
        .sheet(item: $planning, onDismiss: openRouteIfReady) { mode in
            RoutePlannerView(model: model, mode: mode) {
                opensRouteAfterPlanning = true
                planning = nil
            }
        }
        .tint(LumioColor.actionPrimary)
        .onAppear { hasAppeared = true }
        .task { await model.restoreActiveRoute() }
    }

    // MARK: Secciones

    private var brandBar: some View {
        HStack(spacing: 10) {
            LumioMark().frame(width: 36, height: 36)
            Text("Lumio")
                .font(LumioFont.brand(size: 26, relativeTo: .title2))
                .tracking(3)
                .foregroundStyle(LumioColor.brand)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lumio, trayecto")
        .accessibilityAddTraits(.isHeader)
    }

    /// Sin ruta: el mismo lenguaje visual que la bienvenida (símbolo radiante + panel de acción).
    private var emptyState: some View {
        VStack(spacing: 28) {
            LumioRadiantMark(size: 128)
                .padding(.top, 12)
            VStack(spacing: 10) {
                Text("¿A dónde quieres ir?")
                    .font(.title.weight(.bold))
                    .foregroundStyle(LumioColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Indica tu destino y Lumio calcula una ruta a pie desde donde estás.")
                    .font(.body)
                    .foregroundStyle(LumioColor.textSecondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                planning = .create
            } label: {
                Label("Indicar destino", systemImage: "magnifyingglass")
            }
            .buttonStyle(LumioPrimaryButtonStyle())
            .accessibilityHint("Abre la búsqueda de destino.")
        }
        .frame(maxWidth: .infinity)
        .lumioCard(padding: 24, cornerRadius: 28)
    }

    /// Con ruta: lo que quedó en curso va primero y se retoma con una sola acción.
    private func activeRouteSection(_ route: ActiveRoute) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tu ruta activa")
                .font(.title.weight(.bold))
                .foregroundStyle(LumioColor.textPrimary)
                .accessibilityAddTraits(.isHeader)

            RouteSummaryCard(route: route)

            if route.isPendingBackendSync {
                LumioStatusBanner(
                    .warning,
                    message: "Guardada solo en este teléfono. Se guardará en el servidor cuando haya conexión."
                )
            }

            VStack(spacing: 12) {
                Button {
                    showsRoute = true
                } label: {
                    Label("Ver indicaciones", systemImage: "list.number")
                }
                .buttonStyle(LumioPrimaryButtonStyle())
                .accessibilityHint("\(route.steps.count == 1 ? "1 paso" : "\(route.steps.count) pasos") hasta \(route.destination.name).")

                Button {
                    planning = .changeDestination
                } label: {
                    Label("Cambiar destino", systemImage: "arrow.triangle.swap")
                }
                .buttonStyle(LumioSecondaryButtonStyle())
                .accessibilityHint("Calcula una ruta nueva desde donde estás. La actual sigue activa hasta que la nueva esté lista.")
            }
        }
    }

    /// Ayuda breve para el primer uso: tres pasos, nada más.
    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Así funciona")
                .font(.title3.weight(.bold))
                .foregroundStyle(LumioColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 18) {
                HowItWorksRow(
                    number: 1,
                    systemImage: "magnifyingglass",
                    title: "Indica tu destino",
                    detail: "Una dirección o el nombre de un lugar."
                )
                HowItWorksRow(
                    number: 2,
                    systemImage: "figure.walk",
                    title: "Lumio calcula la ruta a pie",
                    detail: "Desde tu ubicación actual."
                )
                HowItWorksRow(
                    number: 3,
                    systemImage: "speaker.wave.2",
                    title: "Escucha las indicaciones",
                    detail: "Te las lee con voz y también las ves en pantalla."
                )
            }
            .lumioCard()
        }
    }

    private var upcomingFeatures: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.headline)
                .foregroundStyle(LumioColor.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Próximamente")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumioColor.textPrimary)
                Text("Guía de giros durante el trayecto, cámara y alertas de obstáculos.")
                    .font(.subheadline)
                    .foregroundStyle(LumioColor.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(LumioColor.controlBorder.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: Acciones

    private func openRouteIfReady() {
        guard opensRouteAfterPlanning else { return }
        opensRouteAfterPlanning = false
        showsRoute = true
    }
}

private struct HowItWorksRow: View {
    let number: Int
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            LumioIconBadge(systemName: systemImage, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(LumioColor.textPrimary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(LumioColor.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Paso \(number): \(title). \(detail)")
    }
}

#if DEBUG
struct DestinationView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            DestinationView(routeCreator: UnavailableNavigationService())
        }
        .previewDisplayName("Sin ruta")
        NavigationStack {
            DestinationView(routeCreator: UnavailableNavigationService())
        }
        .preferredColorScheme(.dark)
        .previewDisplayName("Sin ruta, oscuro")
    }
}
#endif
#endif
