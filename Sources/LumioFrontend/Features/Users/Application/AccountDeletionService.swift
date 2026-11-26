import Foundation

/// Eliminar Cuenta (SCRUM-7):
///
/// 1. Explica por audio las consecuencias y pide una segunda confirmación (la pantalla
///    decide cuándo; aquí solo se locuta).
/// 2. Pide al backend que borre la cuenta (DELETE /users/me). Solo si responde 204 se toca
///    el teléfono: si falla, la cuenta y todo lo local siguen como estaban.
/// 3. Borra lo que la cuenta guarda en el teléfono: el historial pendiente (no se envía, la
///    cuenta ya no existe), la ruta activa, la copia de rutas recientes, los tokens y las
///    preferencias de voz y de vibración (vuelven las predeterminadas).
/// 4. Corta el audio de la sesión y anuncia el resultado; los errores también se locutan.
@MainActor
final class AccountDeletionService: AccountDeleting {
    static let contextID = "account-deletion"

    private let remote: any AccountRemoving
    private let tokens: any TokenStoring
    private let routes: any ActiveRouteStoring
    private let recentRoutes: (any RecentRoutesStoring)?
    private let pendingHistory: (any PendingHistorySyncing)?
    private let voicePreferences: (any VoicePreferencesResetting)?
    private let hapticPreferences: (any HapticPreferencesResetting)?
    private let accessibilityPreferences: (any AccessibilityPreferencesResetting)?
    private let arbiter: (any AudioArbitrating)?
    private let now: () -> Date
    private(set) var isDeleting = false

    init(
        remote: any AccountRemoving,
        tokens: any TokenStoring,
        routes: any ActiveRouteStoring,
        recentRoutes: (any RecentRoutesStoring)? = nil,
        pendingHistory: (any PendingHistorySyncing)? = nil,
        voicePreferences: (any VoicePreferencesResetting)? = nil,
        hapticPreferences: (any HapticPreferencesResetting)? = nil,
        accessibilityPreferences: (any AccessibilityPreferencesResetting)? = nil,
        arbiter: (any AudioArbitrating)?,
        now: @escaping () -> Date = Date.init
    ) {
        self.remote = remote
        self.tokens = tokens
        self.routes = routes
        self.recentRoutes = recentRoutes
        self.pendingHistory = pendingHistory
        self.voicePreferences = voicePreferences
        self.hapticPreferences = hapticPreferences
        self.accessibilityPreferences = accessibilityPreferences
        self.arbiter = arbiter
        self.now = now
    }

    func explainConsequences() {
        speak(AccountDeletionAnnouncements.explanation, key: "consequences")
    }

    func askForFinalConfirmation() {
        speak(AccountDeletionAnnouncements.finalConfirmation, key: "final-confirmation")
    }

    func cancel() {
        guard !isDeleting else { return }
        arbiter?.cancel(contextIDs: [Self.contextID])
    }

    func deleteAccount() async -> AccountDeletionOutcome? {
        guard !isDeleting else { return nil }
        isDeleting = true
        defer { isDeleting = false }
        speak(AccountDeletionAnnouncements.deleting, key: "deleting")

        let outcome: AccountDeletionOutcome
        do {
            try await remote.deleteAccount()
            forgetAccountOnThisPhone()
            outcome = .deleted
        } catch {
            outcome = Self.outcome(for: error)
            // Sin sesión válida no se puede seguir en la app; la cuenta (si existe) sigue.
            if outcome == .sessionExpired { tokens.clear() }
        }
        speak(AccountDeletionAnnouncements.spoken(for: outcome), key: "outcome")
        return outcome
    }

    private func forgetAccountOnThisPhone() {
        pendingHistory?.discardPending()
        try? routes.clear()
        try? recentRoutes?.clear()
        tokens.clear()
        voicePreferences?.resetToStandard()
        hapticPreferences?.resetToStandard()
        accessibilityPreferences?.resetToStandard()
        // Instrucciones de la ruta y cualquier otro mensaje de la cuenta borrada.
        arbiter?.resetSession()
    }

    /// Un mensaje nuevo del flujo reemplaza al anterior (p. ej. al confirmar mientras aún
    /// se explican las consecuencias).
    private func speak(_ text: String, key: String) {
        guard let arbiter else { return }
        arbiter.cancel(contextIDs: [Self.contextID])
        arbiter.receive(AudioMessage(
            text: text,
            priority: .routeInformation,
            createdAt: now(),
            contextID: Self.contextID,
            deduplicationKey: key
        ))
    }

    nonisolated static func outcome(for error: Error) -> AccountDeletionOutcome {
        switch error {
        case AuthenticationError.sessionExpired, AuthenticationError.notSignedIn:
            return .sessionExpired
        // Rechazada aun después de renovar la sesión.
        case HTTPClientError.statusCode(401):
            return .sessionExpired
        case let error as URLError where error.isConnectivityFailure:
            return .offline
        default:
            return .failed
        }
    }
}
