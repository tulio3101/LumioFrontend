import Foundation

/// Registro e inicio de sesión con correo o con Google contra /users. Sin LumioAPIBaseURL
/// (o sin client ID de Google, para Google) se comporta como no disponible.
struct RemoteAuthenticationService: Authenticating {
    let api: AuthAPI?
    let store: any TokenStoring
    /// SCRUM-62: pantalla de Google que entrega el ID token; nil si no está configurado.
    var google: (any GoogleIDTokenProviding)? = nil
    /// SCRUM-360: identidad de la cuenta para reenviar las rutas pendientes del mismo usuario.
    var account: (any CurrentAccountStoring)? = nil
    var pendingHistory: (any PendingHistorySyncing)? = nil

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
        // SCRUM-360: esta cuenta pasa a ser la actual. Si había rutas finalizadas aparcadas a su
        // nombre (de una sesión anterior en este teléfono), ahora se reenvían.
        account?.currentAccountID = CredentialsPolicy.normalizedEmail(credentials.email)
        await pendingHistory?.flush()
    }

    /// Obtiene el ID token de Google, lo envía a POST /users/login/google y guarda los tokens
    /// de Lumio. Si la persona cancela o falla algo, no queda ninguna sesión guardada.
    func signInWithGoogle() async throws {
        guard let api, let google else { throw FeatureUnavailable.authentication }
        let idToken = try await google.requestIDToken()
        let tokens = try await api.loginWithGoogle(idToken: idToken.value)
        do {
            try store.save(tokens)
        } catch {
            throw AuthenticationError.tokenStorageFailed
        }
        // SCRUM-360: misma identidad que con correo (el correo normalizado), para reenviar las
        // rutas aparcadas de esta cuenta.
        if let email = idToken.email {
            account?.currentAccountID = CredentialsPolicy.normalizedEmail(email)
        }
        await pendingHistory?.flush()
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
