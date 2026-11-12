/// Autenticación contra /users. Las implementaciones guardan los tokens en Keychain,
/// nunca en UserDefaults ni en el ViewModel.
protocol Authenticating {
    /// POST /users. No inicia sesión: el backend no devuelve tokens al registrar.
    func register(_ credentials: AccountCredentials) async throws
    /// POST /users/login.
    func signIn(_ credentials: AccountCredentials) async throws
    /// Obtiene el ID token con el SDK de Google y lo envía a POST /users/login/google.
    func signInWithGoogle() async throws
}
