/// Marcador sin backend configurado: nunca hay sesión guardada que restaurar ni cerrar.
struct UnavailableSessionService: SessionRestoring, SessionEnding {
    func hasActiveSession() -> Bool {
        false
    }

    func endSession() async {}
}
