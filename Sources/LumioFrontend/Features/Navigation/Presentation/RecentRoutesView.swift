#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Consultar Rutas Recientes (SCRUM-24): destinos usados antes, del más reciente al más
/// antiguo. Al entrar se locuta cuántos hay (o que no hay ninguno). Elegir uno calcula la
/// ruta desde donde estás; con ruta activa cambia su destino y la actual sigue hasta que la
/// nueva esté lista.
struct RecentRoutesView: View {
    @ObservedObject var model: DestinationViewModel

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsRoute = false
    @State private var hasAnnounced = false
    @State private var now = Date()

    var body: some View {
        ZStack {
            if model.isLoading, let destination = model.pendingDestination {
                CalculatingRouteView(title: calculatingTitle, destination: destination)
                    .transition(.opacity)
            } else {
                content
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.isLoading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LumioColor.background.ignoresSafeArea())
        .navigationTitle("Rutas recientes")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .navigationDestination(isPresented: $showsRoute) {
            ActiveRouteView(model: model)
        }
        .tint(LumioColor.actionPrimary)
        .onAppear { model.dismissFailure() }
        // Se locuta solo la primera vez; al volver de «Tu ruta» se actualiza en silencio.
        .task {
            now = Date()
            let announce = !hasAnnounced
            hasAnnounced = true
            await model.loadRecentRoutes(announce: announce)
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(introduction)
                    .font(.body)
                    .foregroundStyle(LumioColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let failure = model.failure {
                    failureBanner(failure)
                }

                if model.recentRoutesState == .unavailable {
                    unavailableState
                } else if model.recentDestinations.isEmpty {
                    if model.recentRoutesState == .loaded {
                        emptyState
                    } else {
                        loadingState
                    }
                } else {
                    if case let .savedCopy(savedAt) = model.recentRoutesSource {
                        LumioStatusBanner(
                            .warning,
                            title: "Sin conexión",
                            message: "Es la última lista guardada en este teléfono, actualizada "
                                + "\(RecentRoutesAnnouncements.lastUsed(savedAt, now: now))."
                        )
                    }
                    list
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await model.loadRecentRoutes(announce: false) }
    }

    // MARK: Estados

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.recentDestinations.count == 1 ? "1 destino" : "\(model.recentDestinations.count) destinos")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LumioColor.textSecondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(model.recentDestinations.enumerated()), id: \.element.id) { index, recent in
                    if index > 0 {
                        Rectangle()
                            .fill(LumioColor.controlBorder.opacity(0.3))
                            .frame(height: 1)
                            .padding(.leading, 66)
                            .accessibilityHidden(true)
                    }
                    RecentDestinationRow(
                        destination: recent,
                        now: now,
                        isCurrent: model.isCurrentDestination(recent),
                        position: index + 1,
                        total: model.recentDestinations.count,
                        hint: rowHint
                    ) {
                        choose(recent)
                    }
                }
            }
            .lumioCard(padding: 0)
        }
    }

    /// Mismos textos que el anuncio «No tienes rutas recientes».
    private var emptyState: some View {
        VStack(spacing: 14) {
            LumioIconBadge(systemName: "clock", size: 56)
            Text("No tienes rutas recientes")
                .font(.title3.weight(.bold))
                .foregroundStyle(LumioColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Cuando uses una ruta, su destino aparecerá aquí.")
                .font(.body)
                .foregroundStyle(LumioColor.textSecondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .lumioCard(padding: 24)
        .accessibilityElement(children: .combine)
    }

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: 12) {
            LumioStatusBanner(
                .error,
                title: "No se pudieron cargar tus rutas recientes",
                message: "Revisa tu conexión e intenta de nuevo."
            )
            Button {
                Task { await model.loadRecentRoutes(announce: true) }
            } label: {
                Label("Intentar de nuevo", systemImage: "arrow.clockwise")
            }
            .buttonStyle(LumioSecondaryButtonStyle())
        }
    }

    private var loadingState: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(LumioColor.actionPrimary)
            Text("Cargando tus rutas recientes…")
                .font(.body)
                .foregroundStyle(LumioColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }

    private func failureBanner(_ failure: DestinationViewModel.Failure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LumioStatusBanner(
                .error,
                title: model.route == nil ? "No se pudo crear la ruta" : "No se pudo cambiar el destino",
                message: failure.message
            )
            #if os(iOS)
            if failure.recovery == .openSettings, let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Button {
                    openURL(settingsURL)
                } label: {
                    Label("Abrir Ajustes", systemImage: "gearshape")
                }
                .buttonStyle(LumioSecondaryButtonStyle())
            }
            #endif
        }
    }

    // MARK: Acciones

    private func choose(_ recent: RecentDestination) {
        guard !model.isLoading else { return }
        announceForAccessibility("\(calculatingTitle) hacia \(recent.place.name).")
        Task {
            if await model.useRecentDestination(recent) {
                showsRoute = true
            }
        }
    }

    private var introduction: String {
        model.route == nil
            ? "Elige un destino y Lumio calcula la ruta a pie desde donde estás."
            : "Elige un destino para cambiar el de tu ruta activa. La actual sigue hasta que la nueva esté lista."
    }

    private var rowHint: String {
        model.route == nil
            ? "Calcula la ruta a pie hasta este lugar desde donde estás."
            : "Cambia el destino de tu ruta activa a este lugar."
    }

    private var calculatingTitle: String {
        model.route == nil ? "Calculando tu ruta a pie" : "Actualizando tu ruta"
    }
}

/// Un destino reciente: nombre, cuándo se usó por última vez, cómo terminó y cuántas veces.
/// También se usa en la hoja de destino.
struct RecentDestinationRow: View {
    let destination: RecentDestination
    let now: Date
    /// Es el destino de la ruta activa: se muestra pero no se puede elegir.
    let isCurrent: Bool
    let position: Int
    let total: Int
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                LumioIconBadge(systemName: isCurrent ? "figure.walk" : "clock.arrow.circlepath", size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.place.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LumioColor.textPrimary)
                    Text(details.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(LumioColor.textSecondary)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !isCurrent {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LumioColor.controlBorder)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(RecentRowButtonStyle())
        .disabled(isCurrent)
        .accessibilityLabel(destination.place.name)
        .accessibilityValue("\(details.joined(separator: ", ")). \(position) de \(total)")
        .accessibilityHint(isCurrent ? "" : hint)
    }

    private var details: [String] {
        if isCurrent { return ["Es el destino de tu ruta activa"] }
        let lastUsed = RecentRoutesAnnouncements.lastUsed(destination.lastUsedAt, now: now)
        var parts = [
            lastUsed.prefix(1).uppercased() + lastUsed.dropFirst(),
            RecentRoutesAnnouncements.outcome(destination.lastOutcome),
        ]
        if let times = RecentRoutesAnnouncements.timesUsed(destination.timesUsed) {
            parts.append(times)
        }
        return parts
    }
}

private struct RecentRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? LumioColor.background : Color.clear)
    }
}
#endif
