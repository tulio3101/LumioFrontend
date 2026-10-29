/// Marcador explícito: la autenticación aún no existe, así que nunca hay sesión guardada.
/// Sustituir por un adaptador que lea los tokens de Keychain cuando exista el login.
struct UnavailableSessionService: SessionRestoring {
    func hasActiveSession() -> Bool {
        false
    }
}
