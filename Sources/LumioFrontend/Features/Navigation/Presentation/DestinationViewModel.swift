#if canImport(SwiftUI)
import SwiftUI

/// Presenta Crear Ruta. Los anuncios por audio los hace RouteCreationService a través del
/// AudioArbiter; el ViewModel solo refleja el estado en pantalla.
@MainActor
final class DestinationViewModel: ObservableObject {
    /// Fallo mostrado en pantalla junto con la forma de resolverlo.
    struct Failure: Equatable {
        enum Recovery: Equatable {
            /// Corregir el texto del destino (se muestra junto al campo).
            case editDestination
            /// El permiso se concede en Ajustes.
            case openSettings
            /// Fallo transitorio: repetir con el mismo destino.
            case retry
            /// Sin acción posible en esta plataforma.
            case none
        }

        let message: String
        let recovery: Recovery
    }

    /// Entrada provisional: Indicar Destino por Voz (SCRUM-313) entregará el destino confirmado.
    @Published var destination = "" {
        didSet {
            guard destination != oldValue else { return }
            if failure?.recovery == .editDestination { failure = nil }
            if !isApplyingSuggestion { scheduleSuggestions() }
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var route: ActiveRoute?
    @Published private(set) var failure: Failure?
    /// Destino de la operación en curso, para mostrarlo mientras se calcula.
    @Published private(set) var pendingDestination: String?
    /// Sugerencias para `suggestionsQuery`; vacía si no hay o aún no se ha buscado.
    @Published private(set) var suggestions: [DestinationSuggestion] = []
    /// Texto que produjo las sugerencias actuales; nil si no se ha completado una búsqueda.
    @Published private(set) var suggestionsQuery: String?

    private let routeCreator: any RouteCreating
    private let suggester: any DestinationSuggesting
    private let instructions = NavigationInstructionBuilder()
    private var suggestionTask: Task<Void, Never>?
    private var isApplyingSuggestion = false

    /// Sin `suggester` no hay autocompletado (el destino se escribe completo).
    init(routeCreator: any RouteCreating, suggester: (any DestinationSuggesting)? = nil) {
        self.routeCreator = routeCreator
        self.suggester = suggester ?? NoDestinationSuggestions()
    }

    var errorMessage: String? { failure?.message }

    var routeSummary: String? {
        route.map(RouteAnnouncements.ready)
    }

    func spokenText(for step: RouteStep) -> String {
        instructions.spokenText(for: step)
    }

    func restoreActiveRoute() async {
        guard route == nil, !isLoading else { return }
        route = await routeCreator.restoreActiveRoute()
    }

    /// Limpia el fallo anterior al abrir de nuevo la planificación.
    func beginPlanning() {
        guard !isLoading else { return }
        failure = nil
    }

    // MARK: Crear ruta

    /// Con el destino vacío también se llama al servicio: así el aviso se locuta y vibra
    /// igual que cualquier otro fallo, y la pantalla lo muestra junto al campo.
    @discardableResult
    func createRoute() async -> Bool {
        await createRoute(to: .query(destination))
    }

    /// Punto de entrada para un destino ya confirmado (por ejemplo, por voz).
    @discardableResult
    func createRoute(to request: DestinationRequest) async -> Bool {
        await perform(displayName: Self.name(of: request)) { request }
    }

    /// Elegir una sugerencia confirma el destino. Si no se puede ubicar el lugar exacto,
    /// se calcula con su texto completo, así los fallos se siguen locutando.
    @discardableResult
    func selectSuggestion(_ suggestion: DestinationSuggestion) async -> Bool {
        cancelSuggestions()
        isApplyingSuggestion = true
        destination = suggestion.title
        isApplyingSuggestion = false
        return await perform(displayName: suggestion.title) { [suggester] in
            if let place = try? await suggester.place(for: suggestion) {
                return .place(place)
            }
            return .query(suggestion.fullText)
        }
    }

    private func perform(
        displayName: String?,
        request makeRequest: () async -> DestinationRequest
    ) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        failure = nil
        pendingDestination = displayName
        cancelSuggestions()
        defer {
            isLoading = false
            pendingDestination = nil
        }
        do {
            route = try await routeCreator.createRoute(to: await makeRequest())
            return true
        } catch let error as RouteCreationError {
            failure = Failure(message: RouteAnnouncements.failure(error), recovery: Self.recovery(for: error))
        } catch FeatureUnavailable.navigation {
            failure = Failure(
                message: "La creación de rutas no está disponible en esta plataforma.",
                recovery: .none
            )
        } catch {
            failure = Failure(message: RouteAnnouncements.failure(.serviceUnavailable), recovery: .retry)
        }
        return false
    }

    // MARK: Sugerencias

    private func scheduleSuggestions() {
        suggestionTask?.cancel()
        guard let query = DestinationSuggestionPolicy.query(for: destination) else {
            suggestions = []
            suggestionsQuery = nil
            return
        }
        suggestionTask = Task { [weak self, suggester] in
            try? await Task.sleep(nanoseconds: DestinationSuggestionPolicy.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            // Sin conexión o sin resultados, la búsqueda libre sigue funcionando.
            let found = (try? await suggester.suggestions(for: query)) ?? []
            guard !Task.isCancelled, let self, !self.isLoading else { return }
            self.suggestions = DestinationSuggestionPolicy.normalized(found)
            self.suggestionsQuery = query
        }
    }

    private func cancelSuggestions() {
        suggestionTask?.cancel()
        suggestionTask = nil
        suggestions = []
        suggestionsQuery = nil
    }

    // MARK: Apoyo

    private static func recovery(for error: RouteCreationError) -> Failure.Recovery {
        switch error {
        case .emptyDestination, .destinationNotFound, .noRouteAvailable:
            return .editDestination
        case .locationPermissionDenied:
            return .openSettings
        case .locationUnavailable, .localStorageFailed, .serviceUnavailable:
            return .retry
        }
    }

    private static func name(of request: DestinationRequest) -> String? {
        switch request {
        case .query(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .place(let place):
            return place.name
        }
    }
}
#endif
