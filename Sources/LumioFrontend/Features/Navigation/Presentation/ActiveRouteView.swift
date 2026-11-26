#if canImport(SwiftUI)
import SwiftUI

/// Detalle de la ruta activa. Arriba, la indicación que se sigue ahora y la acción para
/// volver a oírla (la principal de la pantalla mientras se camina); después el resumen,
/// el estado del trayecto («¿Cómo voy?», también con el Magic Tap de VoiceOver), el estado
/// del recálculo, «Cambiar destino», «Recalcular ruta» y la lista completa de pasos.
struct ActiveRouteView: View {
    @ObservedObject var model: DestinationViewModel
    /// SCRUM-38: «Describir entorno». nil sin narración (pruebas, otras plataformas).
    var narration: EnvironmentNarrationService? = nil

    @State private var isChangingDestination = false
    @State private var confirmsFinish = false
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var instructionHasFocus: Bool

    var body: some View {
        Group {
            // Con el paso estimado en la última consulta, para que tarjeta, lista y
            // «Repetir» digan lo mismo que se acaba de oír.
            if let route = model.guidanceRoute {
                content(route)
            } else if let finish = model.lastFinish {
                FinishedRouteView(result: finish) {
                    model.acknowledgeFinish()
                    dismiss()
                }
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
                focusInstruction()
            }
        }
        .onAppear {
            focusInstruction()
            // SCRUM-40: la narración vigila cambios de escena solo mientras se ve la ruta.
            if model.guidanceRoute != nil { narration?.startAutoUpdates() }
        }
        // «Ruta actualizada» se confirma una sola vez: al volver a esta pantalla ya no está.
        .onDisappear {
            model.acknowledgeRouteUpdate()
            narration?.stopAutoUpdates()
        }
        // La ruta se finaliza sin salir de esta vista: deja de vigilar al instante.
        .onChange(of: model.guidanceRoute == nil) { noRoute in
            if noRoute { narration?.stopAutoUpdates() }
        }
        // Prevención de errores y estado honesto en el historial: el usuario dice si llegó.
        .confirmationDialog("¿Finalizar la ruta?", isPresented: $confirmsFinish, titleVisibility: .visible) {
            Button("Llegué a mi destino") { finish(.completed) }
            Button("Terminar sin llegar", role: .destructive) { finish(.cancelled) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se detienen las indicaciones y la ruta se guarda en tu historial.")
        }
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
                if let reroute = model.rerouteStatus {
                    RerouteStatusBanner(status: reroute)
                }
                if let step = route.currentInstruction {
                    CurrentInstructionCard(
                        step: step,
                        total: route.steps.count,
                        spokenText: model.spokenText(for: step),
                        focus: $instructionHasFocus,
                        onQueryStatus: model.startRouteStatusQuery,
                        onReroute: recalculate,
                        onFinish: { confirmsFinish = true }
                    ) {
                        model.repeatCurrentInstruction()
                    }
                }
                // Justo después de la indicación: con VoiceOver se llega con un deslizamiento.
                if let narration {
                    DescribeEnvironmentButton(service: narration)
                }
                RouteSummaryCard(route: route)
                RouteProgressCard(
                    route: route,
                    progress: model.currentProgress,
                    checkedAt: model.statusCheckedAt,
                    isQuerying: model.isQueryingStatus,
                    onQuery: model.startRouteStatusQuery
                )
                if route.isPendingBackendSync {
                    LumioStatusBanner(
                        .warning,
                        title: "Guardada solo en este teléfono",
                        message: "Puedes seguirla sin problema. Se guardará en el servidor la próxima vez que abras Lumio con conexión."
                    )
                }
                // Antes de los pasos: con VoiceOver se llega sin recorrer toda la lista.
                Button {
                    isChangingDestination = true
                } label: {
                    Label("Cambiar destino", systemImage: "arrow.triangle.swap")
                }
                .buttonStyle(LumioSecondaryButtonStyle())
                .accessibilityHint("Calcula una ruta nueva desde donde estás. La actual sigue activa hasta que la nueva esté lista.")
                Button(action: recalculate) {
                    if model.isRerouting {
                        ProgressView()
                            .tint(LumioColor.actionPrimary)
                    } else {
                        Label("Recalcular ruta", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(LumioSecondaryButtonStyle())
                .disabled(model.isRerouting || model.isFinishing)
                // SCRUM-29: mientras recalcula, VoiceOver lo dice en lugar de solo atenuarlo.
                .accessibilityLabel(model.isRerouting ? "Recalculando la ruta" : "Recalcular ruta")
                .accessibilityHint("Calcula de nuevo la ruta al mismo destino desde donde estás. Necesita conexión.")
                Button {
                    confirmsFinish = true
                } label: {
                    if model.isFinishing {
                        ProgressView()
                            .tint(LumioColor.actionPrimary)
                    } else {
                        Label("Finalizar ruta", systemImage: "flag.checkered")
                    }
                }
                .buttonStyle(LumioSecondaryButtonStyle())
                .disabled(model.isFinishing)
                .accessibilityLabel(model.isFinishing ? "Finalizando la ruta" : "Finalizar ruta")
                .accessibilityHint("Detiene las indicaciones y guarda la ruta en tu historial. Pide confirmación.")
                stepsSection(route)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        // Magic Tap (doble toque con dos dedos): Consultar Ruta sin buscar el botón. La
        // respuesta ya incluye la siguiente indicación.
        // Magic Tap solo existe en iOS (no disponible en macOS; la compilación portable lo omite).
        #if os(iOS)
        .accessibilityAction(.magicTap) {
            model.startRouteStatusQuery()
        }
        #endif
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

    private func finish(_ outcome: RouteHistoryEntry.Outcome) {
        Task { await model.finishRoute(outcome: outcome) }
    }

    private func recalculate() {
        Task { await model.recalculateRoute() }
    }

    /// Al llegar (o al cambiar de ruta) VoiceOver empieza por la indicación actual, no por
    /// la barra de navegación.
    private func focusInstruction() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { instructionHasFocus = true }
    }
}

// MARK: Componentes de ruta

/// La indicación que se sigue ahora, en grande, con la acción para volver a oírla.
private struct CurrentInstructionCard: View {
    let step: RouteStep
    let total: Int
    let spokenText: String
    let focus: AccessibilityFocusState<Bool>.Binding
    let onQueryStatus: () -> Void
    let onReroute: () -> Void
    let onFinish: () -> Void
    let onRepeat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Ahora")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(LumioColor.actionPrimary)
                    Spacer(minLength: 0)
                    Text("Paso \(step.order + 1) de \(total)")
                        .font(.subheadline)
                        .foregroundStyle(LumioColor.textSecondary)
                }
                Text(step.instruction)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(LumioColor.textPrimary)
                if step.distanceMeters >= 1 {
                    Label(
                        "Continúa \(SpokenDistance.text(meters: step.distanceMeters))",
                        systemImage: "arrow.up"
                    )
                    .font(.headline)
                    .foregroundStyle(LumioColor.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Ahora, paso \(step.order + 1) de \(total): \(spokenText)")
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused(focus)
            // Desde el primer elemento que lee VoiceOver, en el menú de acciones.
            .accessibilityAction(named: "Consultar ruta", onQueryStatus)
            .accessibilityAction(named: "Recalcular ruta", onReroute)
            .accessibilityAction(named: "Finalizar ruta", onFinish)

            Button(action: onRepeat) {
                Label("Repetir indicación", systemImage: "speaker.wave.2.fill")
            }
            .buttonStyle(LumioPrimaryButtonStyle())
            .accessibilityHint("La vuelve a leer en voz alta.")
        }
        .lumioCard()
    }
}

/// Estado de Recalcular Ruta (SCRUM-26), con los mismos textos que se locutan.
struct RerouteStatusBanner: View {
    let status: RerouteStatus

    var body: some View {
        switch status {
        case .rerouting:
            HStack(spacing: 12) {
                ProgressView()
                    .tint(LumioColor.actionPrimary)
                Text(status.message)
                    .font(.headline)
                    .foregroundStyle(LumioColor.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lumioCard(padding: 16)
            .accessibilityElement(children: .combine)
        case .rerouted:
            LumioStatusBanner(.success, title: "Ruta recalculada", message: status.message)
        case .waitingForConnection:
            LumioStatusBanner(.warning, title: "Sin conexión", message: status.message)
        case .failed:
            LumioStatusBanner(.error, title: "No se pudo recalcular", message: status.message)
        }
    }
}

/// Ruta finalizada: confirma cómo terminó y que se guarda en el historial. Mismos textos
/// que el anuncio.
struct FinishedRouteView: View {
    let result: RouteFinishResult
    let onDone: () -> Void

    @AccessibilityFocusState private var titleHasFocus: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                LumioIconBadge(
                    systemName: result.finished.outcome == .completed ? "flag.checkered" : "stop.circle",
                    size: 72
                )
                .padding(.top, 24)
                VStack(spacing: 10) {
                    Text(RouteFinishAnnouncements.title(result))
                        .font(.title.weight(.bold))
                        .foregroundStyle(LumioColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($titleHasFocus)
                    Text(RouteFinishAnnouncements.finished(result))
                        .font(.headline)
                        .foregroundStyle(LumioColor.textSecondary)
                    Text(RouteFinishAnnouncements.historyNote)
                        .font(.subheadline)
                        .foregroundStyle(LumioColor.textSecondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                Button(action: onDone) {
                    Label("Volver al inicio", systemImage: "house")
                }
                .buttonStyle(LumioPrimaryButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { titleHasFocus = true }
        }
    }
}

/// Estado del trayecto: resultado de la última consulta y la acción «¿Cómo voy?». Muestra
/// los mismos textos que se locutan. También se usa en el inicio.
struct RouteProgressCard: View {
    let route: ActiveRoute
    let progress: RouteProgress?
    let checkedAt: Date?
    let isQuerying: Bool
    let onQuery: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Estado del trayecto")
                        .font(.headline)
                        .foregroundStyle(LumioColor.textPrimary)
                    Spacer(minLength: 0)
                    if progress != nil, let checkedAt {
                        Text("Consultado a las \(checkedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(LumioColor.textSecondary)
                    }
                }
                if let progress {
                    ProgressView(value: progress.fraction)
                        .tint(LumioColor.actionPrimary)
                        .accessibilityHidden(true)
                    Text(RouteStatusAnnouncements.progressSentence(progress))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LumioColor.textPrimary)
                    Text(nextText(progress))
                        .font(.subheadline)
                        .foregroundStyle(LumioColor.textSecondary)
                    if progress.basis == .storedStep {
                        Label(RouteStatusAnnouncements.approximateNote, systemImage: "location.slash")
                            .font(.footnote)
                            .foregroundStyle(LumioColor.warningText)
                    }
                } else {
                    Text("Escucha cuánto llevas, cuánto te falta y la siguiente indicación.")
                        .font(.subheadline)
                        .foregroundStyle(LumioColor.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            Button(action: onQuery) {
                if isQuerying {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(LumioColor.actionPrimary)
                        Text("Consultando…")
                    }
                } else {
                    Label("¿Cómo voy?", systemImage: "waveform")
                }
            }
            .buttonStyle(LumioSecondaryButtonStyle())
            .disabled(isQuerying)
            .accessibilityLabel(isQuerying ? "Consultando tu ruta" : "¿Cómo voy?")
            .accessibilityHint(
                "Te dice por voz el destino, cuánto llevas y la siguiente indicación. "
                    + "Con VoiceOver también puedes tocar dos veces con dos dedos."
            )
        }
        .lumioCard()
    }

    private func nextText(_ progress: RouteProgress) -> String {
        if progress.isArriving, let step = progress.nextStep { return "\(step.instruction)." }
        return RouteStatusAnnouncements.nextSentence(progress, in: route)
    }
}

/// Destino, distancia, duración y estado de guardado. También se usa en el inicio.
struct RouteSummaryCard: View {
    let route: ActiveRoute

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
                    Text("Ahora")
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
        return isCurrent ? "\(position), ahora: \(spokenText)" : "\(position): \(spokenText)"
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

extension DestinationViewModel {
    /// Lanza Consultar Ruta desde la vista. Con ruta, VoiceOver avisa de que empezó: la
    /// lectura del GPS puede tardar un par de segundos.
    func startRouteStatusQuery() {
        guard !isQueryingStatus, !isLoading else { return }
        if route != nil { announceForAccessibility("Consultando tu ruta.") }
        Task { await queryRouteStatus() }
    }
}
/// SCRUM-38: pide una descripción del entorno. El resultado llega por audio (P3): no
/// interrumpe alertas ni indicaciones. Mientras se describe, el botón no envía otra foto.
private struct DescribeEnvironmentButton: View {
    @ObservedObject var service: EnvironmentNarrationService

    var body: some View {
        Button {
            service.requestDescription()
        } label: {
            if service.isDescribing {
                Label("Describiendo el entorno…", systemImage: "ellipsis")
            } else {
                Label("Describir entorno", systemImage: "eye")
            }
        }
        .buttonStyle(LumioSecondaryButtonStyle())
        .disabled(service.isDescribing)
        .accessibilityLabel(service.isDescribing ? "Describiendo el entorno" : "Describir entorno")
        .accessibilityHint("Toma una foto con la cámara y describe por audio lo que tienes delante. Necesita conexión.")
    }
}
#endif
