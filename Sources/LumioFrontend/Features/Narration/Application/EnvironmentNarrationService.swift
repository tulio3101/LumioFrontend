import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SCRUM-38: Narración del Entorno. Canal completo, de la foto al audio:
///
/// 1. Sin consentimiento vigente (SCRUM-324) no se toma ninguna foto: lo explica el servicio
///    de consentimiento.
/// 2. Sin conexión no se intenta: se informa y la detección sigue (SCRUM-262, 266).
/// 3. Toma una foto del `ARSession` que ya corre para la seguridad (SCRUM-261).
/// 4. La envía a `POST /vision/analyze` y recibe la descripción ya limpia (SCRUM-262–264).
/// 5. La encola en el AudioArbiter como P3 (`NarrationAudio`): no interrumpe alertas ni
///    indicaciones y se descarta si espera demasiado (SCRUM-265).
/// 6. Cualquier falla se informa por audio y nunca toca el loop de seguridad (SCRUM-266, 267).
///
/// Una sola solicitud en vuelo. Si la respuesta llega más de 4 s después de la foto, se
/// descarta: ya no describe lo que el usuario tiene delante (ADR-308).
///
/// SCRUM-40: el mismo canal sirve a las actualizaciones automáticas (`trigger: .auto`) que
/// pide `AutoNarrationScheduler` cuando la escena cambia. Esas no avisan «Describiendo…» ni
/// hablan al fallar: el usuario no las pidió y repetir un aviso cada pocos segundos lo
/// molestaría más que ayudarlo.
@MainActor
final class EnvironmentNarrationService: ObservableObject {
    /// Avisos de estado de la narración. Distinto de `NarrationAudio.contextID` para que una
    /// descripción nueva no se cancele junto con «Describiendo…».
    static let statusContextID = "narration-status"
    /// ADR-308: la descripción vale hasta 4 s después de tomar la foto.
    static let maxResponseAge: TimeInterval = 4
    /// ADR-308: «Describiendo…» solo si la respuesta tarda más de esto.
    static let describingNoticeDelay: TimeInterval = 1.5

    @Published private(set) var isDescribing = false
    /// SCRUM-40: cuándo se envió la última foto al backend (botón o automática). El
    /// planificador cuenta el mínimo entre narraciones desde aquí.
    private(set) var lastRequestAt: Date?
    /// SCRUM-40: avisa de cada descripción que entró al árbitro, con la foto que la originó,
    /// para que el planificador tome esa escena como la última narrada.
    var onDescribed: ((NarrationFrame) -> Void)?
    /// SCRUM-40: actualizaciones automáticas por cambio de escena (opcional).
    var autoUpdates: AutoNarrationScheduler?

    private let capturer: (any NarrationFrameCapturing)?
    private let describer: any EnvironmentDescribing
    private let consent: any NarrationConsentGating
    private let connectivity: any ConnectivityObserving
    private let arbiter: (any AudioArbitrating)?
    /// Se borran si la sesión ya no vale, para que la app vuelva a pedir iniciar sesión.
    private let tokens: (any TokenStoring)?
    /// SCRUM-39: huella de la foto para no volver a describir una escena que no cambió.
    private let signatures: (any SceneSignatureProviding)?
    private let repeatPolicy: NarrationRepeatPolicy
    /// SCRUM-39: la última descripción pedida a mano, para repetirla sin volver a enviar.
    private var lastDescription: (text: String, capturedAt: Date, signature: SceneSignature?)?
    private let sleep: (TimeInterval) async throws -> Void
    private let now: () -> Date

    private var request: Task<EnvironmentNarrationOutcome, Never>?
    private var captureSequence: UInt64 = 0

    init(
        capturer: (any NarrationFrameCapturing)?,
        describer: any EnvironmentDescribing,
        consent: any NarrationConsentGating,
        connectivity: any ConnectivityObserving,
        arbiter: (any AudioArbitrating)?,
        tokens: (any TokenStoring)? = nil,
        signatures: (any SceneSignatureProviding)? = nil,
        repeatPolicy: NarrationRepeatPolicy = NarrationRepeatPolicy(),
        sleep: @escaping (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.capturer = capturer
        self.describer = describer
        self.consent = consent
        self.connectivity = connectivity
        self.arbiter = arbiter
        self.tokens = tokens
        self.signatures = signatures
        self.repeatPolicy = repeatPolicy
        self.sleep = sleep
        self.now = now
    }

    /// Botón «Describir entorno», comando de voz o acción de VoiceOver (SCRUM-39). No
    /// espera: el resultado llega por audio. Si ya hay una en curso no se envía otra y se dice.
    func requestDescription() {
        guard request == nil, !isDescribing else {
            say(EnvironmentNarrationMessages.alreadyDescribing, key: "already-describing", priority: .environmentInformation)
            return
        }
        request = Task { [weak self] in
            await self?.describeEnvironment() ?? .cancelled
        }
    }

    /// Corta la solicitud en vuelo y lo que estuviera por sonar (p. ej., al retirar el
    /// consentimiento). No dice nada: quien cancela ya lo informa.
    func cancel() {
        autoUpdates?.stop()
        request?.cancel()
        request = nil
        isDescribing = false
        // Con el consentimiento retirado tampoco se repite lo descrito antes.
        lastDescription = nil
        arbiter?.cancel(contextIDs: [NarrationAudio.contextID, Self.statusContextID])
    }

    /// SCRUM-40: con el planificador activo, empieza a vigilar los cambios de escena. Lo llama
    /// la pantalla de la ruta activa.
    func startAutoUpdates() { autoUpdates?.start() }
    func stopAutoUpdates() { autoUpdates?.stop() }

    /// `preCapturedFrame`: la foto que el planificador ya tomó para comparar escenas; así la
    /// automática no abre una segunda captura. Sin ella, el servicio toma la suya.
    @discardableResult
    func describeEnvironment(
        trigger: NarrationTrigger = .gesture, preCapturedFrame: NarrationFrame? = nil
    ) async -> EnvironmentNarrationOutcome {
        guard !isDescribing else { return .alreadyDescribing }
        defer { request = nil }
        if trigger == .auto {
            // Una automática nunca habla: sin consentimiento vigente simplemente no sale.
            guard consent.consentVersionForUpload != nil else { return .consentRequired }
        } else {
            guard consent.requireConsentBeforeNarration() else { return .consentRequired }
        }
        guard connectivity.isConnected else { return unavailable(.offline, trigger: trigger) }
        guard preCapturedFrame != nil || capturer != nil else {
            return unavailable(.cameraInactive, trigger: trigger)
        }
        // SCRUM-39: pedir otra vez enseguida repite la última descripción, sin foto ni red.
        if trigger == .gesture, let last = lastDescription,
           repeatPolicy.replaysWithoutPhoto(lastCapturedAt: last.capturedAt, now: now()) {
            return replay(last.text)
        }

        isDescribing = true
        defer { isDescribing = false }
        let notice = Task { [weak self, sleep] in
            try? await sleep(Self.describingNoticeDelay)
            guard !Task.isCancelled, trigger == .gesture else { return }
            self?.announceDescribing()
        }
        // Si «Describiendo…» llegó a sonar, lo reemplaza el aviso de falla (`say`) o se corta
        // antes de encolar la descripción.
        defer { notice.cancel() }

        let frame: NarrationFrame
        if let preCapturedFrame {
            frame = preCapturedFrame
        } else if let capturer {
            switch await capturer.captureNarrationFrame() {
            case .frame(let captured): frame = captured
            case .cameraInactive: return unavailable(.cameraInactive, trigger: trigger)
            case .noUsableFrame: return unavailable(.noUsableFrame, trigger: trigger)
            }
        } else {
            return unavailable(.cameraInactive, trigger: trigger)
        }
        if Task.isCancelled { return .cancelled }
        // Pudo retirarse mientras se tomaba la foto: entonces no se envía.
        guard let version = consent.consentVersionForUpload else { return .cancelled }
        // SCRUM-39: si la escena es la misma que se acaba de describir, se repite sin enviar.
        let signature = trigger == .gesture ? signatures?.signature(for: frame.jpeg) : nil
        if let last = lastDescription, repeatPolicy.replaysSameScene(
            last: last.signature, lastCapturedAt: last.capturedAt, current: signature, now: now()
        ) {
            return replay(last.text)
        }

        let text: String
        lastRequestAt = now()
        do {
            text = try await describer.describe(frame, trigger: trigger, consentVersion: version)
        } catch {
            if Task.isCancelled || error is CancellationError { return .cancelled }
            return unavailable(Self.reason(for: error), trigger: trigger)
        }
        if Task.isCancelled { return .cancelled }
        guard now().timeIntervalSince(frame.capturedAt) <= Self.maxResponseAge else {
            return unavailable(.stale, trigger: trigger)
        }
        notice.cancel()
        arbiter?.cancel(contextIDs: [Self.statusContextID])
        captureSequence += 1
        arbiter?.receive(NarrationAudio.message(
            text: text, capturedAt: frame.capturedAt, captureSequence: captureSequence
        ))
        onDescribed?(frame)
        if trigger == .gesture {
            lastDescription = (text, frame.capturedAt, signature)
        }
        return .described(text)
    }

    /// SCRUM-39: repite la última descripción como P3, igual que una nueva.
    private func replay(_ text: String) -> EnvironmentNarrationOutcome {
        captureSequence += 1
        arbiter?.cancel(contextIDs: [Self.statusContextID])
        arbiter?.receive(NarrationAudio.message(
            text: EnvironmentNarrationMessages.repeated(text),
            capturedAt: now(),
            captureSequence: captureSequence
        ))
        return .repeated(text)
    }

    // MARK: Errores

    nonisolated static func reason(for error: Error) -> EnvironmentNarrationUnavailable {
        switch error {
        case let urlError as URLError where urlError.code == .timedOut:
            return .timedOut
        case let urlError as URLError where urlError.isConnectivityFailure:
            return .offline
        case AuthenticationError.notSignedIn, AuthenticationError.sessionExpired,
             HTTPClientError.statusCode(401):
            return .sessionRequired
        case FeatureUnavailable.authentication, FeatureUnavailable.navigation:
            return .notConfigured
        case HTTPClientError.statusCode(429):
            return .rateLimited
        case HTTPClientError.statusCode(504):
            return .timedOut
        default:
            // 403, 413, 422, 5xx o una respuesta ilegible: para el usuario, no disponible.
            return .serviceUnavailable
        }
    }

    // MARK: Audio

    private func unavailable(
        _ reason: EnvironmentNarrationUnavailable, trigger: NarrationTrigger = .gesture
    ) -> EnvironmentNarrationOutcome {
        if reason == .sessionRequired { tokens?.clear() }
        // SCRUM-40: una actualización automática que falla se calla; el planificador espera
        // antes de volver a intentar y el botón sigue informando sus propias fallas.
        if trigger == .auto { return .unavailable(reason) }
        say(EnvironmentNarrationMessages.message(for: reason), key: "unavailable", priority: .routeInformation)
        return .unavailable(reason)
    }

    private func announceDescribing() {
        guard isDescribing else { return }
        say(EnvironmentNarrationMessages.describing, key: "describing", priority: .environmentInformation)
    }

    private func say(_ text: String, key: String, priority: AudioPriority) {
        guard let arbiter else { return }
        arbiter.cancel(contextIDs: [Self.statusContextID])
        arbiter.receive(AudioMessage(
            text: text,
            priority: priority,
            createdAt: now(),
            expiresAt: now().addingTimeInterval(10),
            contextID: Self.statusContextID,
            deduplicationKey: key
        ))
    }
}
