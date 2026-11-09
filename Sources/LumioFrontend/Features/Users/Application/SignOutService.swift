import Foundation

/// Cerrar sesión desde la app: revoca la sesión, borra la ruta guardada en el teléfono
/// (pertenece a esa cuenta) y detiene el audio pendiente.
@MainActor
protocol SigningOut {
    func signOut() async
}

@MainActor
struct SignOutService: SigningOut {
    let session: any SessionEnding
    let routes: any ActiveRouteStoring
    let arbiter: (any AudioArbitrating)?

    func signOut() async {
        await session.endSession()
        try? routes.clear()
        arbiter?.resetSession()
    }
}
