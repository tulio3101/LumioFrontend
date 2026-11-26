/// Marcador sin backend configurado: nunca hay sesión guardada que restaurar ni cerrar.
struct UnavailableSessionService: SessionRestoring, SessionEnding {
    func hasActiveSession() -> Bool {
        false
    }

    func endSession() async {}
}

/// Sin Keychain (fuera de iOS): no guarda tokens.
struct NoTokenStore: TokenStoring {
    func load() -> AuthTokens? { nil }
    func save(_ tokens: AuthTokens) throws {}
    func clear() {}
}
