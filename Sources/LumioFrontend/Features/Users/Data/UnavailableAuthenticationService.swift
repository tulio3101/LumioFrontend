/// Marcador explícito: no simula cuentas ni sesiones hasta conectar /users y el SDK de Google.
struct UnavailableAuthenticationService: Authenticating {
    func register(_ credentials: AccountCredentials) async throws {
        throw FeatureUnavailable.authentication
    }

    func signIn(_ credentials: AccountCredentials) async throws {
        throw FeatureUnavailable.authentication
    }

    func signInWithGoogle() async throws {
        throw FeatureUnavailable.authentication
    }
}
