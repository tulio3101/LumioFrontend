#if canImport(SwiftUI)
import SwiftUI

/// Presenta Crear Ruta, Modificar Ruta, Consultar Ruta y Consultar Rutas Recientes. Los anuncios por audio los hacen
/// los servicios a través del AudioArbiter; el ViewModel solo refleja el estado en pantalla.
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

    /// Qué hace la hoja de planificación con el destino indicado.
    enum PlanningMode: Hashable, Identifiable {
        /// Crear Ruta (SCRUM-8).
        case create
        /// Modificar Ruta (SCRUM-9): misma ruta, nuevo destino.
        case changeDestination

        var id: Self { self }
    }

    /// Carga de los destinos recientes (SCRUM-24).
    enum RecentRoutesState: Equatable {
        case idle
        case loading
        case loaded
        /// Sin backend y sin copia guardada: se ofrece reintentar.
        case unavailable
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
    @Published private(set) var planningMode: PlanningMode = .create
    /// Revisión de la ruta recién actualizada, para confirmarlo en pantalla una sola vez:
    /// se borra al salir de «Tu ruta» (`acknowledgeRouteUpdate`) o al volver a planificar.
    @Published private(set) var updatedRevision: Int?
    @Published private(set) var isQueryingStatus = false
    /// Resultado de la última consulta del estado de la ruta y cuándo se hizo.
    @Published private(set) var routeStatus: RouteStatus?
    @Published private(set) var statusCheckedAt: Date?
    @Published private(set) var recentDestinations: [RecentDestination] = []
    @Published private(set) var recentRoutesSource: RecentRoutes.Source?
    @Published private(set) var recentRoutesState: RecentRoutesState = .idle

    private let routeCreator: any RouteCreating
    private let routeModifier: any RouteModifying
    private let instructionRepeater: any InstructionRepeating
    private let routeStatusQuery: any RouteStatusQuerying
    private let recentRoutes: any RecentRoutesQuerying
    private let suggester: any DestinationSuggesting
    private let instructions = NavigationInstructionBuilder()
    private var suggestionTask: Task<Void, Never>?
    private var isApplyingSuggestion = false

    /// Sin `suggester` no hay autocompletado (el destino se escribe completo). Sin
    /// `routeModifier` no se puede cambiar el destino; sin `instructionRepeater`, no se
    /// puede repetir la indicación; sin `routeStatusQuery`, no se puede consultar la ruta;
    /// sin `recentRoutes`, no hay destinos recientes.
    init(
        routeCreator: any RouteCreating,
        routeModifier: (any RouteModifying)? = nil,
        instructionRepeater: (any InstructionRepeating)? = nil,
        routeStatusQuery: (any RouteStatusQuerying)? = nil,
        recentRoutes: (any RecentRoutesQuerying)? = nil,
        suggester: (any DestinationSuggesting)? = nil
    ) {
        self.routeCreator = routeCreator
        self.routeModifier = routeModifier ?? UnavailableNavigationService()
        self.instructionRepeater = instructionRepeater ?? UnavailableNavigationService()
        self.routeStatusQuery = routeStatusQuery ?? UnavailableNavigationService()
        self.recentRoutes = recentRoutes ?? UnavailableNavigationService()
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

    /// Prepara la hoja. Al cambiar de destino el campo empieza vacío: se pide uno nuevo.
    func beginPlanning(_ mode: PlanningMode) {
        guard !isLoading else { return }
        failure = nil
        updatedRevision = nil
        if mode == .changeDestination {
            destination = ""
        }
        planningMode = mode
    }

    /// La confirmación «Ruta actualizada» ya se vio: no se vuelve a mostrar.
    func acknowledgeRouteUpdate() {
        updatedRevision = nil
    }

    // MARK: Indicaciones

    /// Vuelve a locutar la indicación actual (la estimada en la última consulta, si la hay).
    @discardableResult
    func repeatCurrentInstruction() -> Bool {
        guard let route = guidanceRoute, !isLoading else { return false }
        return instructionRepeater.repeatCurrentInstruction(of: route)
    }

    // MARK: Consultar ruta

    /// Avance de la última consulta, si corresponde a la ruta (y revisión) que se muestra.
    var currentProgress: RouteProgress? {
        guard case let .active(queried, progress)? = routeStatus, let route,
              queried.id == route.id, queried.revision == route.revision else { return nil }
        return progress
    }

    /// La ruta con el paso que la última consulta estimó como siguiente. Solo para mostrar
    /// y repetir; no se guarda (avanzar el paso es de Guiar Giros, SCRUM-312).
    var guidanceRoute: ActiveRoute? {
        guard var route else { return nil }
        if let next = currentProgress?.nextStep { route.currentStep = next.order }
        return route
    }

    /// Consultar Ruta Actual (Magic Tap o «¿Cómo voy?»). El servicio locuta el resultado,
    /// también cuando no hay ruta; aquí solo se refleja en pantalla.
    @discardableResult
    func queryRouteStatus() async -> RouteStatus? {
        guard !isLoading, !isQueryingStatus else { return nil }
        isQueryingStatus = true
        defer { isQueryingStatus = false }
        let status = await routeStatusQuery.queryActiveRoute()
        // Si mientras se esperaba el GPS empezó a crearse o cambiarse la ruta, esa operación
        // decide la ruta que se muestra.
        guard !isLoading else { return status }
        switch status {
        case let .active(queried, _):
            route = queried
        case .noActiveRoute, .unreadable:
            route = nil
        }
        routeStatus = status
        statusCheckedAt = Date()
        return status
    }

    // MARK: Rutas recientes

    /// Hasta 5 para la hoja de destino, sin el destino de la ruta activa.
    var plannerRecents: [RecentDestination] {
        RecentRoutesPolicy.plannerDestinations(recentDestinations, excluding: route?.destination)
    }

    /// El destino reciente es el de la ruta activa: elegirlo no cambiaría nada.
    func isCurrentDestination(_ destination: RecentDestination) -> Bool {
        route.map { RecentRoutesPolicy.isSamePlace(destination.place, $0.destination) } ?? false
    }

    /// Carga los destinos recientes. Con `announce`, el servicio locuta el resultado.
    func loadRecentRoutes(announce: Bool) async {
        guard recentRoutesState != .loading else { return }
        recentRoutesState = .loading
        do {
            let result = try await recentRoutes.recentRoutes(announce: announce)
            recentDestinations = result.destinations
            recentRoutesSource = result.source
            recentRoutesState = .loaded
        } catch {
            recentDestinations = []
            recentRoutesSource = nil
            recentRoutesState = .unavailable
        }
    }

    /// Usar un destino reciente sin escribirlo: se calcula la ruta hasta ese lugar desde
    /// donde estás. Sin `mode` (pantalla de rutas recientes), con ruta activa se cambia su
    /// destino y sin ella se crea una; en la hoja se respeta el modo de la hoja.
    @discardableResult
    func useRecentDestination(_ recent: RecentDestination, mode: PlanningMode? = nil) async -> Bool {
        guard !isLoading else { return false }
        planningMode = mode ?? (route == nil ? .create : .changeDestination)
        isApplyingSuggestion = true
        destination = recent.place.name
        isApplyingSuggestion = false
        return await perform(displayName: recent.place.name) { .place(recent.place) }
    }

    /// Al entrar a una pantalla nueva no se arrastra el fallo de otra.
    func dismissFailure() {
        failure = nil
    }

    // MARK: Crear ruta

    /// Envía el texto escrito según el modo de la hoja. Con el destino vacío también se
    /// llama al servicio: así el aviso se locuta y vibra igual que cualquier otro fallo.
    @discardableResult
    func submitDestination() async -> Bool {
        switch planningMode {
        case .create: return await createRoute(to: .query(destination))
        case .changeDestination: return await changeDestination(to: .query(destination))
        }
    }

    /// Punto de entrada para un destino ya confirmado (por ejemplo, por voz).
    @discardableResult
    func createRoute(to request: DestinationRequest) async -> Bool {
        planningMode = .create
        return await perform(displayName: Self.name(of: request)) { request }
    }

    /// Modificar Ruta. Punto de entrada de Indicar Destino por Voz (SCRUM-313): el dictado
    /// confirmado llega aquí igual que en Crear Ruta.
    @discardableResult
    func changeDestination(to request: DestinationRequest) async -> Bool {
        planningMode = .changeDestination
        return await perform(displayName: Self.name(of: request)) { request }
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

    /// Ejecuta la operación del modo actual. Si cambiar el destino falla, `route` no cambia:
    /// la ruta anterior sigue activa.
    private func perform(
        displayName: String?,
        request makeRequest: () async -> DestinationRequest
    ) async -> Bool {
        guard !isLoading else { return false }
        let mode = planningMode
        let previous = route
        isLoading = true
        failure = nil
        pendingDestination = displayName
        cancelSuggestions()
        defer {
            isLoading = false
            pendingDestination = nil
        }
        do {
            let request = await makeRequest()
            switch mode {
            case .create:
                route = try await routeCreator.createRoute(to: request)
                updatedRevision = nil
            case .changeDestination:
                let changed = try await routeModifier.changeDestination(to: request)
                route = changed
                updatedRevision = changed.revision
            }
            return true
        } catch let error as RouteCreationError {
            let message = mode == .changeDestination
                ? RouteAnnouncements.modificationFailure(error, keeping: previous)
                : RouteAnnouncements.failure(error)
            failure = Failure(message: message, recovery: Self.recovery(for: error))
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
        case .emptyDestination, .destinationNotFound, .noRouteAvailable, .sameDestination:
            return .editDestination
        case .locationPermissionDenied:
            return .openSettings
        case .locationUnavailable, .localStorageFailed, .serviceUnavailable:
            return .retry
        case .noActiveRoute:
            return .none
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
