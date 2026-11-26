import Foundation

/// Avisos de audio de «Continuar con Google» (SCRUM-62). Prioridad de información
/// (`routeInformation`) en su propio contexto; un aviso nuevo reemplaza al anterior.
@MainActor
final class GoogleSignInAnnouncer {
    private let arbiter: (any AudioArbitrating)?
    private let connectivity: (any ConnectivityObserving)?
    private let now: () -> Date

    init(
        arbiter: (any AudioArbitrating)?,
        connectivity: (any ConnectivityObserving)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.arbiter = arbiter
        self.connectivity = connectivity
        self.now = now
    }

    /// Solo cuando se sabe que no hay red (el monitor asume conexión antes de su primera lectura).
    var isOffline: Bool { connectivity?.isConnected == false }

    func announce(_ failure: GoogleSignInFailure) {
        guard let arbiter else { return }
        arbiter.cancel(contextIDs: [GoogleSignInAnnouncements.contextID])
        arbiter.receive(AudioMessage(
            text: GoogleSignInAnnouncements.message(for: failure),
            priority: .routeInformation,
            createdAt: now(),
            expiresAt: now().addingTimeInterval(60),
            contextID: GoogleSignInAnnouncements.contextID,
            deduplicationKey: "google-\(failure)"
        ))
    }
}

/// Añade al inicio de sesión los avisos por audio del flujo de Google: sin red (antes de abrir
/// la pantalla de Google), cancelación y cualquier otro error. El correo y el registro pasan
/// tal cual. Los errores se relanzan ya traducidos a GoogleSignInFailure para la pantalla.
/// Al entrar no se locuta nada aquí: la pantalla principal anuncia su estado al abrirse.
struct AnnouncedAuthenticationService: Authenticating {
    let base: any Authenticating
    let announcer: GoogleSignInAnnouncer

    func register(_ credentials: AccountCredentials) async throws {
        try await base.register(credentials)
    }

    func signIn(_ credentials: AccountCredentials) async throws {
        try await base.signIn(credentials)
    }

    func signInWithGoogle() async throws {
        if await announcer.isOffline {
            await announcer.announce(.offline)
            throw GoogleSignInFailure.offline
        }
        do {
            try await base.signInWithGoogle()
        } catch {
            let failure = GoogleSignInFailure.from(error)
            await announcer.announce(failure)
            throw failure
        }
    }
}
