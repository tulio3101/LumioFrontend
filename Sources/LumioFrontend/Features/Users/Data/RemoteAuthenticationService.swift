import Foundation

/// Registro e inicio de sesión con correo contra /users. Google sigue sin conectar.
/// Sin LumioAPIBaseURL configurada se comporta como no disponible.
struct RemoteAuthenticationService: Authenticating {
    let api: AuthAPI?
    let store: any TokenStoring

    func register(_ credentials: AccountCredentials) async throws {
        guard let api else { throw FeatureUnavailable.authentication }
        try await api.register(email: credentials.email, password: credentials.password)
    }

    func signIn(_ credentials: AccountCredentials) async throws {
        guard let api else { throw FeatureUnavailable.authentication }
        let tokens = try await api.login(email: credentials.email, password: credentials.password)
        do {
            try store.save(tokens)
        } catch {
            throw AuthenticationError.tokenStorageFailed
        }
    }

    func signInWithGoogle() async throws {
        throw FeatureUnavailable.authentication
    }
}

/// Sesión basada en los tokens guardados: decide la primera pantalla sin red y la cierra.
struct StoredSessionService: SessionRestoring, SessionEnding {
    let api: AuthAPI?
    let store: any TokenStoring

    func hasActiveSession() -> Bool {
        store.load() != nil
    }

    /// Revoca la sesión en el backend si hay conexión; los tokens locales se borran siempre.
    func endSession() async {
        if let api, let tokens = store.load() {
            try? await api.logout(tokens.refreshToken)
        }
        store.clear()
    }
}
