/// Primera pantalla de la app según la sesión guardada.
enum AppEntry: Equatable {
    case welcome
    case home

    init(session: any SessionRestoring) {
        self = session.hasActiveSession() ? .home : .welcome
    }
}
