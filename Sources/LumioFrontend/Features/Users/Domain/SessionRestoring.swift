/// Decide la primera pantalla al abrir la app. Debe responder de forma local y síncrona
/// (p. ej. si hay tokens en Keychain), sin red, para no mostrar la bienvenida mientras
/// se comprueba la sesión. Validar el token con GET /users/me después, ya dentro de la app.
protocol SessionRestoring {
    func hasActiveSession() -> Bool
}
