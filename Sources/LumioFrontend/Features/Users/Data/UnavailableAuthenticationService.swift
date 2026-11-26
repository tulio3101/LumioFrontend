/// Marcador explícito para plataformas sin backend: no simula cuentas ni sesiones.
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
