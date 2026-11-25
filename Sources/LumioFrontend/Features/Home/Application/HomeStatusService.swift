import Foundation

/// Pantalla Principal Accesible: al abrir la app informa por audio el estado relevante
/// (sesión, permisos, seguridad y ruta activa). Habla una sola vez por apertura; después se
/// puede repetir a pedido. Todo es local y pasa por el AudioArbiter como P2, así que una
/// alerta crítica siempre lo interrumpe.
@MainActor
final class HomeStatusService {
    static let contextID = "home-status"

    private let session: any SessionRestoring
    private let permissions: (any PermissionStatusReading)?
    private let safetyModel: any SafetyModelChecking
    private let routes: any ActiveRouteStoring
    private let arbiter: (any AudioArbitrating)?
    private let now: () -> Date
    private(set) var hasAnnounced = false

    init(
        session: any SessionRestoring,
        permissions: (any PermissionStatusReading)?,
        safetyModel: any SafetyModelChecking,
        routes: any ActiveRouteStoring,
        arbiter: (any AudioArbitrating)?,
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.permissions = permissions
        self.safetyModel = safetyModel
        self.routes = routes
        self.arbiter = arbiter
        self.now = now
    }

    func snapshot() async -> HomeStatusSnapshot {
        let statuses = await permissions?.statuses() ?? [:]
        let safety: SafetyReadiness
        if !safetyModel.isModelAvailable() {
            safety = .modelMissing
        } else if [.denied, .restricted, .unavailable].contains(statuses[.camera]) {
            safety = .cameraDenied
        } else {
            safety = .ready
        }
        let route = try? routes.load()
        return HomeStatusSnapshot(
            isSignedIn: session.hasActiveSession(),
            permissions: statuses,
            safety: safety,
            activeRouteDestination: route?.destination.name
        )
    }

    /// Al aparecer la pantalla principal. Solo la primera vez por apertura de la app.
    @discardableResult
    func announceOnLaunch() async -> String? {
        guard !hasAnnounced else { return nil }
        hasAnnounced = true
        return await announce()
    }

    /// «Estado de Lumio»: repite el estado actual a pedido.
    @discardableResult
    func announce() async -> String {
        let text = HomeAnnouncements.welcome(await snapshot())
        if let arbiter {
            arbiter.cancel(contextIDs: [Self.contextID])
            arbiter.receive(AudioMessage(
                text: text,
                priority: .routeInformation,
                createdAt: now(),
                expiresAt: now().addingTimeInterval(60),
                contextID: Self.contextID,
                deduplicationKey: "status"
            ))
        }
        return text
    }
}

/// Sin modelo de detección (plataformas sin la app iOS).
struct NoSafetyModel: SafetyModelChecking {
    func isModelAvailable() -> Bool { false }
}

#if os(iOS)
/// El modelo YOLO compilado viene en el bundle de la app (el mismo que carga YOLORunner).
struct BundleSafetyModelChecker: SafetyModelChecking {
    func isModelAvailable() -> Bool {
        Bundle.main.url(forResource: "yolo26n_640_int8", withExtension: "mlmodelc") != nil
    }
}
#endif
