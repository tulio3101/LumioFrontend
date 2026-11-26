import Foundation

extension Notification.Name {
    /// La publica el cliente HTTP cuando el refresh token ya no vale (401 y refresh rechazado):
    /// la sesión expiró. Con ruta activa NO se desmonta nada todavía (la seguridad no depende del
    /// backend); sin ruta activa, se desmonta en el acto.
    static let lumioSessionExpired = Notification.Name("lumio.sessionExpired")
    /// La publica el ViewModel al finalizar o llegar: si la sesión había expirado durante la ruta,
    /// AQUÍ se ejecuta el teardown y se pide iniciar sesión.
    static let lumioRouteEnded = Notification.Name("lumio.routeEnded")
}

/// Al expirar la sesión (401 no renovable), SCRUM-360:
/// - CON ruta activa: no apaga nada (navegación y detección siguen; la seguridad no depende del
///   backend). Avisa una sola vez por audio (prioridad de navegación) que la ruta continúa sin
///   sincronizar. El teardown se difiere hasta finalizar/llegar.
/// - SIN ruta activa: desmonta en el acto y devuelve la UI al login.
/// Reutiliza el MISMO `SessionTeardown` que el cierre de sesión.
@MainActor
final class SessionExpiryCoordinator: ObservableObject {
    private let teardown: any SessionTearingDown
    private let routes: any ActiveRouteStoring
    private let arbiter: (any AudioArbitrating)?
    private let notifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    /// true cuando ya se desmontó por expiración: la UI (RootView) vuelve a la bienvenida/login.
    @Published private(set) var didExpire = false
    /// Expiró con ruta activa: se espera a que termine para desmontar.
    private(set) var awaitingRouteEnd = false

    init(
        teardown: any SessionTearingDown,
        routes: any ActiveRouteStoring,
        arbiter: (any AudioArbitrating)? = nil,
        notifications: NotificationCenter = .default
    ) {
        self.teardown = teardown
        self.routes = routes
        self.arbiter = arbiter
        self.notifications = notifications
        observers.append(notifications.addObserver(
            forName: .lumioSessionExpired, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.handleExpiry() } })
        observers.append(notifications.addObserver(
            forName: .lumioRouteEnded, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.handleRouteEnded() } })
    }

    deinit {
        for observer in observers { notifications.removeObserver(observer) }
    }

    private var hasActiveRoute: Bool { ((try? routes.load()) ?? nil) != nil }

    /// Procesa la expiración. Idempotente mientras ya esté expirada o esperando el fin de ruta.
    func handleExpiry() async {
        guard !didExpire, !awaitingRouteEnd else { return }
        if hasActiveRoute {
            // Hay ruta: NO apagar la detección ni la navegación. Avisar una sola vez.
            awaitingRouteEnd = true
            FeedbackCatalog.emit(.sessionExpired, audio: arbiter)
        } else {
            await finishTeardown()
        }
    }

    /// Al terminar/llegar: si la sesión había expirado durante la ruta, desmontar ahora y pedir login.
    func handleRouteEnded() async {
        guard awaitingRouteEnd else { return }
        awaitingRouteEnd = false
        await finishTeardown()
    }

    private func finishTeardown() async {
        await teardown.tearDown()
        didExpire = true
    }
}
