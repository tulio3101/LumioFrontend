import Foundation

/// Cerrar sesión desde la app: revoca la sesión, borra lo que pertenece a esa cuenta en el
/// teléfono (la ruta y la copia de rutas recientes) y detiene el audio pendiente.
@MainActor
protocol SigningOut {
    func signOut() async
}

@MainActor
struct SignOutService: SigningOut {
    let session: any SessionEnding
    let routes: any ActiveRouteStoring
    let arbiter: (any AudioArbitrating)?
    /// Así otra cuenta en el mismo teléfono no ve los destinos de la anterior.
    var recentRoutes: (any RecentRoutesStoring)?

    func signOut() async {
        await session.endSession()
        try? routes.clear()
        try? recentRoutes?.clear()
        arbiter?.resetSession()
    }
}
