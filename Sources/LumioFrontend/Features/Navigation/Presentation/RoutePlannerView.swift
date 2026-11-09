#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Planificar una ruta o cambiar su destino: una sola tarea en su propia hoja (indicar
/// destino → calcular). El resultado y los fallos ya se locutan por el AudioArbiter, así que
/// aquí no se repiten como anuncios de VoiceOver; solo se anuncia el inicio del cálculo.
struct RoutePlannerView: View {
    @ObservedObject var model: DestinationViewModel
    let mode: DestinationViewModel.PlanningMode
    /// Se llama cuando la ruta quedó lista; quien presenta la hoja decide a dónde ir.
    let onRouteReady: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var fieldIsFocused: Bool
    /// Cantidad anunciada por última vez, para no repetir el anuncio en cada tecla.
    @State private var announcedSuggestionCount = 0

    var body: some View {
        NavigationStack {
            ZStack {
                if model.isLoading, let destination = model.pendingDestination {
                    CalculatingRouteView(title: copy.calculatingTitle, destination: destination)
                        .transition(.opacity)
                } else {
                    form
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.isLoading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LumioColor.background.ignoresSafeArea())
            .navigationTitle(copy.navigationTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                        .disabled(model.isLoading)
                }
            }
        }
        .tint(LumioColor.actionPrimary)
        // Mientras se calcula no se puede cerrar: la ruta podría quedar a medio crear.
        .interactiveDismissDisabled(model.isLoading)
        .onChange(of: model.suggestions) { suggestions in
            announceSuggestionsIfNeeded(suggestions)
        }
        .onAppear {
            model.beginPlanning(mode)
            // Tras la animación de la hoja, para que el teclado no la interrumpa.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { fieldIsFocused = true }
        }
    }

    // MARK: Formulario

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                destinationField
                suggestionsSection
                if let failure = model.failure, failure.recovery != .editDestination {
                    failureBanner(failure)
                        .transition(.opacity)
                }
                originNote
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.suggestions)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isTyping)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { submitBar }
    }

    private var header: some View {
        // Al escribir, el encabezado se compacta para dejar las sugerencias sobre el teclado.
        VStack(alignment: .leading, spacing: 12) {
            if !isTyping {
                LumioIconBadge(systemName: "mappin.and.ellipse", size: 56)
                    .transition(.opacity)
            }
            Text(copy.heading)
                .font(isTyping ? .title2.weight(.bold) : .largeTitle.weight(.bold))
                .foregroundStyle(LumioColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if !isTyping {
                Text(copy.subheading(currentDestination: model.route?.destination.name))
                    .font(.body)
                    .foregroundStyle(LumioColor.textSecondary)
                    .transition(.opacity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var destinationField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dirección o lugar")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LumioColor.textPrimary)
                .accessibilityHidden(true)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(LumioColor.textSecondary)
                    .accessibilityHidden(true)
                TextField("Dirección o lugar", text: $model.destination, prompt: Text("Ej.: Farmacia Central"))
                    .font(.body)
                    .foregroundStyle(LumioColor.textPrimary)
                    .focused($fieldIsFocused)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .destinationInput()
                    .accessibilityHint(
                        fieldError ?? "Al escribir aparecen sugerencias debajo. También puedes pulsar \(copy.submitLabel)."
                    )
                if !model.destination.isEmpty {
                    Button {
                        model.destination = ""
                        fieldIsFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(LumioColor.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Borrar destino")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .frame(minHeight: 56)
            .background(LumioColor.surface, in: fieldShape)
            .overlay(fieldShape.strokeBorder(fieldBorder, lineWidth: fieldIsFocused || fieldError != nil ? 2 : 1))

            if let fieldError {
                Label(fieldError, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(LumioColor.errorText)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            } else {
                Text("Escribe al menos \(DestinationSuggestionPolicy.minimumQueryLength) letras para ver sugerencias.")
                    .font(.footnote)
                    .foregroundStyle(LumioColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Hace visible de dónde parte la ruta (el usuario no tiene que indicarlo).
    private var originNote: some View {
        HStack(alignment: .top, spacing: 14) {
            LumioIconBadge(systemName: "location.fill", size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sales desde tu ubicación actual")
                    .font(.headline)
                    .foregroundStyle(LumioColor.textPrimary)
                Text("Lumio la pide una sola vez al calcular la ruta.")
                    .font(.subheadline)
                    .foregroundStyle(LumioColor.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .lumioCard(padding: 16, cornerRadius: 18)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        if !model.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sugerencias")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumioColor.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        if index > 0 {
                            Rectangle()
                                .fill(LumioColor.controlBorder.opacity(0.3))
                                .frame(height: 1)
                                .padding(.leading, 66)
                                .accessibilityHidden(true)
                        }
                        SuggestionRow(
                            suggestion: suggestion,
                            position: index + 1,
                            total: model.suggestions.count
                        ) {
                            select(suggestion)
                        }
                    }
                }
                .lumioCard(padding: 0, cornerRadius: 18)
            }
            .transition(.opacity)
        } else if let query = model.suggestionsQuery, fieldError == nil {
            Label(
                "Sin sugerencias para «\(query)». Puedes calcular la ruta con lo que escribiste.",
                systemImage: "info.circle"
            )
            .font(.footnote)
            .foregroundStyle(LumioColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
        }
    }

    private func failureBanner(_ failure: DestinationViewModel.Failure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LumioStatusBanner(.error, title: copy.failureTitle, message: failure.message)
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

    // MARK: Acción principal

    /// Siempre visible y al alcance del pulgar, encima del teclado.
    private var submitBar: some View {
        Button(action: submit) {
            Label(submitLabel, systemImage: "figure.walk")
        }
        .buttonStyle(LumioPrimaryButtonStyle())
        .disabled(model.isLoading)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background(LumioColor.background.ignoresSafeArea())
    }

    private var copy: PlannerCopy {
        mode == .changeDestination ? .changeDestination : .create
    }

    private var isTyping: Bool {
        !model.destination.isEmpty
    }

    private func select(_ suggestion: DestinationSuggestion) {
        guard !model.isLoading else { return }
        fieldIsFocused = false
        announceForAccessibility("\(copy.calculatingTitle) hacia \(suggestion.title).")
        Task {
            if await model.selectSuggestion(suggestion) {
                onRouteReady()
            } else if model.failure?.recovery == .editDestination {
                fieldIsFocused = true
            }
        }
    }

    /// Solo cuando cambia la cantidad: avisar en cada tecla saturaría a VoiceOver.
    private func announceSuggestionsIfNeeded(_ suggestions: [DestinationSuggestion]) {
        guard suggestions.count != announcedSuggestionCount else { return }
        let previous = announcedSuggestionCount
        announcedSuggestionCount = suggestions.count
        if let message = DestinationSuggestionPolicy.announcement(count: suggestions.count) {
            announceForAccessibilityQueued(message)
        } else if previous > 0, model.suggestionsQuery != nil {
            announceForAccessibilityQueued("Sin sugerencias.")
        }
    }

    private var submitLabel: String {
        model.failure?.recovery == .retry ? "Intentar de nuevo" : copy.submitLabel
    }

    private func submit() {
        guard !model.isLoading else { return }
        fieldIsFocused = false
        if model.pendingDestinationWillBeValid {
            announceForAccessibility("\(copy.calculatingTitle).")
        }
        Task {
            if await model.submitDestination() {
                onRouteReady()
            } else if model.failure?.recovery == .editDestination {
                fieldIsFocused = true
            }
        }
    }

    private var fieldError: String? {
        guard let failure = model.failure, failure.recovery == .editDestination else { return nil }
        return failure.message
    }

    private var fieldBorder: Color {
        if fieldError != nil { return LumioColor.errorText }
        return fieldIsFocused ? LumioColor.actionPrimary : LumioColor.controlBorder
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }
}

/// Textos de la hoja según el modo: mismo flujo, distinta intención.
private struct PlannerCopy {
    let navigationTitle: String
    let heading: String
    let submitLabel: String
    let calculatingTitle: String
    let failureTitle: String
    let isChange: Bool

    func subheading(currentDestination: String?) -> String {
        if isChange, let currentDestination {
            return "Tu ruta hacia \(currentDestination) sigue activa hasta que la nueva esté lista. "
                + "La nueva ruta sale desde donde estás ahora."
        }
        return "Escribe una dirección o el nombre de un lugar. Lumio calcula la ruta a pie y te la lee paso a paso."
    }

    static let create = PlannerCopy(
        navigationTitle: "Nueva ruta",
        heading: "¿A dónde quieres ir?",
        submitLabel: "Calcular ruta",
        calculatingTitle: "Calculando tu ruta a pie",
        failureTitle: "No se pudo crear la ruta",
        isChange: false
    )

    static let changeDestination = PlannerCopy(
        navigationTitle: "Cambiar destino",
        heading: "¿A dónde quieres ir ahora?",
        submitLabel: "Cambiar destino",
        calculatingTitle: "Actualizando tu ruta",
        failureTitle: "No se pudo cambiar el destino",
        isChange: true
    )
}

/// Una sugerencia: nombre, dirección y posición en la lista para orientarse con VoiceOver.
private struct SuggestionRow: View {
    let suggestion: DestinationSuggestion
    let position: Int
    let total: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                LumioIconBadge(systemName: "mappin", size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LumioColor.textPrimary)
                    if !suggestion.subtitle.isEmpty {
                        Text(suggestion.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(LumioColor.textSecondary)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LumioColor.controlBorder)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(SuggestionButtonStyle())
        .accessibilityLabel(suggestion.fullText)
        .accessibilityValue("Sugerencia \(position) de \(total)")
        .accessibilityHint("Calcula la ruta a pie hasta este lugar.")
    }
}

private struct SuggestionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? LumioColor.background : Color.clear)
    }
}

/// Estado de espera: el símbolo irradia mientras se calcula (sin movimiento si se reduce).
private struct CalculatingRouteView: View {
    let title: String
    let destination: String

    var body: some View {
        VStack(spacing: 32) {
            LumioRadiantMark(size: 132, isWorking: true)
                .padding(.top, 24)
            VStack(spacing: 10) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(LumioColor.textPrimary)
                Text("Hacia \(destination)")
                    .font(.headline)
                    .foregroundStyle(LumioColor.actionPrimary)
                Text("Buscamos tu ubicación, el destino y el camino peatonal. Te avisaremos con voz cuando esté lista.")
                    .font(.subheadline)
                    .foregroundStyle(LumioColor.textSecondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            ProgressView()
                .tint(LumioColor.actionPrimary)
                .accessibilityHidden(true)
        }
        .padding(24)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) hacia \(destination).")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private extension DestinationViewModel {
    /// Evita anunciar «Calculando» cuando el destino está vacío (el fallo llega al instante).
    var pendingDestinationWillBeValid: Bool {
        !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private extension View {
    func destinationInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.sentences)
            .autocorrectionDisabled()
            .textContentType(.fullStreetAddress)
        #else
        autocorrectionDisabled()
        #endif
    }
}
#endif
