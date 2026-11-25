import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Botón de Emergencia (SCRUM-35):
///
/// 1. `activate()` da feedback al instante (háptica y audio, que recuerda que no sustituye
///    al 123) y abre un margen de 10 s para cancelar; mientras tanto va pidiendo la
///    ubicación, sin pedir permiso, y comprueba que haya contactos de confianza.
/// 2. Sin contactos no hay margen que esperar: se informa de inmediato y no se envía nada.
/// 3. `cancel()` durante el margen no envía nada y lo dice por audio.
/// 4. Al terminar el margen se envía POST /sos con la ubicación (si hay). Sin conexión se
///    informa que no se pudo enviar. Con la misma alerta, `retry()` reenvía sin nueva cuenta
///    atrás, con la misma llave, así que nunca duplica correos.
/// 5. Todo resultado se locuta por el AudioArbiter con prioridad inmediata (contexto
///    `emergency`) y con háptica de activación, éxito o error.
@MainActor
final class EmergencyService: EmergencyManaging {
    static let contextID = "emergency"
    static let countdownSeconds = 10
    /// Segundo de la cuenta atrás en que se vuelve a avisar por audio.
    static let reminderSecond = 5

    private let remote: any EmergencyRemoting
    private let locator: any EmergencyLocating
    private let connectivity: any ConnectivityObserving
    /// Cuántos contactos de confianza hay; nil si no se pudo saber (el backend decide al enviar).
    private let contactCount: () async -> Int?
    /// Se borran si la sesión ya no vale, para que la app vuelva a pedir iniciar sesión.
    private let tokens: (any TokenStoring)?
    private let arbiter: (any AudioArbitrating)?
    private let haptics: any HapticFeedbackPlaying
    private let makeKey: () -> UUID
    private let sleep: (TimeInterval) async throws -> Void
    private let now: () -> Date

    var onPhaseChange: ((EmergencyPhase) -> Void)?
    private(set) var phase: EmergencyPhase = .idle {
        didSet { onPhaseChange?(phase) }
    }

    private var run: Task<Void, Never>?
    private var locationTask: Task<EmergencyLocation?, Never>?
    /// Resultado de la comprobación de contactos durante el margen.
    private var knownContactCount: Int?
    /// La última alerta enviada, para reintentar con la misma llave.
    private var lastAlert: EmergencyAlert?

    init(
        remote: any EmergencyRemoting,
        locator: any EmergencyLocating,
        connectivity: any ConnectivityObserving,
        contactCount: @escaping () async -> Int? = { nil },
        tokens: (any TokenStoring)? = nil,
        arbiter: (any AudioArbitrating)?,
        haptics: any HapticFeedbackPlaying,
        makeKey: @escaping () -> UUID = UUID.init,
        sleep: @escaping (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.remote = remote
        self.locator = locator
        self.connectivity = connectivity
        self.contactCount = contactCount
        self.tokens = tokens
        self.arbiter = arbiter
        self.haptics = haptics
        self.makeKey = makeKey
        self.sleep = sleep
        self.now = now
    }

    // MARK: Acciones

    func activate() {
        guard !phase.isBusy else { return }
        let key = makeKey()
        knownContactCount = nil
        lastAlert = nil
        phase = .countingDown(secondsRemaining: Self.countdownSeconds)
        haptics.play(.emergencyActivated)
        speak(EmergencyAnnouncements.activated(seconds: Self.countdownSeconds))
        run = Task { [weak self] in await self?.countdownThenSend(key: key) }
    }

    func cancel() {
        guard case .countingDown = phase else { return }
        run?.cancel()
        locationTask?.cancel()
        run = nil
        locationTask = nil
        phase = .cancelled
        speak(EmergencyAnnouncements.cancelled)
    }

    func retry() {
        guard case .failed(let failure) = phase, failure.canRetry, let alert = lastAlert else { return }
        // Ya en `.sending`: un segundo toque no puede lanzar otro envío.
        phase = .sending
        run = Task { [weak self] in await self?.send(alert) }
    }

    func dismiss() {
        guard !phase.isBusy else { return }
        phase = .idle
    }

    // MARK: Flujo

    private func countdownThenSend(key: UUID) async {
        locationTask = Task { [locator] in await locator.currentLocation() }
        // Mientras corre el margen se averigua si hay contactos; sin ellos no tiene sentido esperar.
        let check = Task { [weak self] in
            let count = await self?.contactCount()
            self?.knownContactCount = count
        }
        defer { check.cancel() }

        var remaining = Self.countdownSeconds
        while remaining > 0 {
            if knownContactCount == 0 {
                fail(.noContacts)
                return
            }
            phase = .countingDown(secondsRemaining: remaining)
            if remaining == Self.reminderSecond { speak(EmergencyAnnouncements.countdown(remaining)) }
            do { try await sleep(1) } catch { return }
            if Task.isCancelled { return }
            remaining -= 1
        }
        if knownContactCount == 0 {
            fail(.noContacts)
            return
        }
        let location = await locationTask?.value
        await send(EmergencyAlert(idempotencyKey: key, location: location))
    }

    private func send(_ alert: EmergencyAlert) async {
        lastAlert = alert
        phase = .sending
        speak(EmergencyAnnouncements.sending)
        // Sin red conocida no se intenta: se dice de inmediato en lugar de esperar al tiempo límite.
        guard connectivity.isConnected else {
            fail(.offline)
            return
        }
        do {
            let delivery = try await remote.send(alert)
            run = nil
            phase = .sent(delivery)
            haptics.play(.emergencySent)
            speak(EmergencyAnnouncements.sent(delivery))
        } catch {
            fail(Self.failure(for: error))
        }
    }

    private func fail(_ failure: EmergencyFailure) {
        run = nil
        if failure == .sessionExpired { tokens?.clear() }
        phase = .failed(failure)
        haptics.play(.emergencyFailed)
        speak(EmergencyAnnouncements.failed(failure))
    }

    /// Un mensaje nuevo reemplaza al anterior del mismo flujo. Prioridad máxima: lo que el
    /// usuario pidió en una emergencia pasa por delante de la navegación.
    private func speak(_ text: String) {
        guard let arbiter else { return }
        arbiter.cancel(contextIDs: [Self.contextID])
        arbiter.receive(AudioMessage(
            text: text,
            priority: .immediateRisk,
            createdAt: now(),
            contextID: Self.contextID
        ))
    }

    nonisolated static func failure(for error: Error) -> EmergencyFailure {
        switch error {
        case AuthenticationError.sessionExpired, AuthenticationError.notSignedIn,
             HTTPClientError.statusCode(401):
            return .sessionExpired
        case HTTPClientError.statusCode(409):
            return .noContacts
        case HTTPClientError.statusCode(502):
            return .deliveryFailed
        case let error as URLError where error.isConnectivityFailure:
            return .offline
        default:
            return .server
        }
    }
}
