/// Autenticación contra /users. Las implementaciones guardan los tokens en Keychain,
/// nunca en UserDefaults ni en el ViewModel.
protocol Authenticating {
    /// POST /users. No inicia sesión: el backend no devuelve tokens al registrar.
    func register(_ credentials: AccountCredentials) async throws
    /// POST /users/login.
    func signIn(_ credentials: AccountCredentials) async throws
    /// Obtiene el ID token de Google (GoogleIDTokenProviding) y lo envía a POST
    /// /users/login/google. Los errores del flujo son GoogleSignInFailure.
    func signInWithGoogle() async throws
}
