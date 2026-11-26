import Foundation

/// SCRUM-40: Actualizar Narración ante Cambios de Entorno (ADR-308, loop lento).
///
/// Mientras hay una ruta activa, cada `pollInterval` revisa si conviene volver a narrar. Las
/// comprobaciones van de la más barata a la más cara, y solo la última llega a la red:
///
/// 1. Consentimiento vigente, conexión, narración disponible (SCRUM-41), ninguna otra
///    descripción en vuelo y tope de la ruta.
/// 2. Pausa tras una falla y mínimo de 10 s desde la última narración (botón o automática).
/// 3. Canal de audio libre: una narración nueva nunca espera detrás de una alerta o una
///    indicación, ni se acumula.
/// 4. Foto del `ARSession` de la seguridad y su huella (`VNFeaturePrint`), en el teléfono.
/// 5. Solo si la huella se aleja de la última escena narrada se envía la foto a
///    `POST /vision/analyze` con `trigger=auto`.
///
/// Nada de esto llama al loop de seguridad ni espera por él: una falla de red o del backend
/// solo hace que no haya narración nueva. Las fallas no se locutan (ver `describeEnvironment`).
@MainActor
final class AutoNarrationScheduler {
    enum SkipReason: Equatable {
        case consentRequired
        case offline
        /// SCRUM-41: la narración está caída; no se toma foto hasta que vuelva.
        case narrationUnavailable
        case describing
        case routeBudgetExhausted
        case backingOff
        case tooSoon
        case channelBusy
        case noFrame
        case noSignature
        case sameScene
    }

    enum Decision: Equatable {
        case notRunning
        case skipped(SkipReason)
        /// Primera foto de la ruta: se toma como escena de referencia sin narrar.
        case baselineSet
        case requested(EnvironmentNarrationOutcome)
    }

    private weak var service: EnvironmentNarrationService?
    private let capturer: any NarrationFrameCapturing
    private let signatures: any SceneSignatureProviding
    private let consent: any NarrationConsentChecking
    private let connectivity: any ConnectivityObserving
    private let channel: (any AudioChannelObserving)?
    private let configuration: AutoNarrationConfiguration
    private let isLowPowerMode: () -> Bool
    private let sleep: (TimeInterval) async throws -> Void
    private let now: () -> Date

    private(set) var isRunning = false
    private var loop: Task<Void, Never>?
    /// Última escena narrada: la referencia contra la que se mide el cambio.
    private var baseline: SceneSignature?
    private var requestsThisRoute = 0
    private var consecutiveFailures = 0
    private var backoffUntil: Date?

    init(
        service: EnvironmentNarrationService,
        capturer: any NarrationFrameCapturing,
        signatures: any SceneSignatureProviding,
        consent: any NarrationConsentChecking,
        connectivity: any ConnectivityObserving,
        channel: (any AudioChannelObserving)?,
        configuration: AutoNarrationConfiguration = AutoNarrationConfiguration(),
        isLowPowerMode: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        sleep: @escaping (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.capturer = capturer
        self.signatures = signatures
        self.consent = consent
        self.connectivity = connectivity
        self.channel = channel
        self.configuration = configuration
        self.isLowPowerMode = isLowPowerMode
        self.sleep = sleep
        self.now = now
    }

    // MARK: Ciclo de vida

    /// Empieza a vigilar la escena de una ruta. Cada ruta parte de cero: sin escena de
    /// referencia, sin fallas y con todo su tope de solicitudes.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        baseline = nil
        requestsThisRoute = 0
        consecutiveFailures = 0
        backoffUntil = nil
        // Si el usuario pide una descripción con el botón, esa escena pasa a ser la narrada.
        service?.onDescribed = { [weak self] frame in
            self?.baseline = self?.signatures.signature(for: frame.jpeg)
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await self.sleep(self.configuration.pollInterval)
                guard !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    /// Fin de la ruta, consentimiento retirado o la pantalla ya no está: deja de vigilar y
    /// corta la solicitud automática que estuviera en vuelo.
    func stop() {
        isRunning = false
        loop?.cancel()
        loop = nil
        service?.onDescribed = nil
    }

    /// SCRUM-41: la narración volvió. Se olvida la pausa por fallas para que la siguiente vuelta
    /// pueda narrar enseguida; la escena de referencia y el tope de la ruta se conservan.
    func resume() {
        consecutiveFailures = 0
        backoffUntil = nil
    }

    // MARK: Una vuelta del loop

    /// Una revisión. Pública para probar cada decisión sin esperar el reloj.
    @discardableResult
    func tick() async -> Decision {
        guard isRunning, let service else { return .notRunning }

        // 1. Condiciones locales y baratas.
        guard consent.consentVersionForUpload != nil else { return .skipped(.consentRequired) }
        guard connectivity.isConnected else { return .skipped(.offline) }
        guard !service.narrationAvailability.isUnavailable else {
            return .skipped(.narrationUnavailable)
        }
        guard !service.isDescribing else { return .skipped(.describing) }
        guard requestsThisRoute < configuration.maxRequestsPerRoute else {
            return .skipped(.routeBudgetExhausted)
        }

        // 2. Ritmo: pausa tras fallas y mínimo entre narraciones.
        let current = now()
        if let until = backoffUntil, current < until { return .skipped(.backingOff) }
        if let last = service.lastRequestAt,
           current.timeIntervalSince(last) < effectiveMinInterval {
            return .skipped(.tooSoon)
        }

        // 3. Canal libre.
        guard channel?.isChannelFree ?? true else { return .skipped(.channelBusy) }

        // 4. Foto y huella, sin red.
        guard case .frame(let frame) = await capturer.captureNarrationFrame() else {
            return .skipped(.noFrame)
        }
        guard isRunning else { return .notRunning }
        guard let signature = signatures.signature(for: frame.jpeg) else {
            return .skipped(.noSignature)
        }
        guard let reference = baseline else {
            baseline = signature
            return .baselineSet
        }
        guard let distance = reference.distance(to: signature) else {
            // Huellas incomparables (otra revisión del generador): se parte de esta.
            baseline = signature
            return .skipped(.noSignature)
        }
        guard distance >= configuration.changeThreshold else { return .skipped(.sameScene) }

        // 5. La captura tardó: se vuelve a mirar que nada haya cambiado mientras tanto.
        guard consent.consentVersionForUpload != nil else { return .skipped(.consentRequired) }
        guard !service.isDescribing else { return .skipped(.describing) }
        guard channel?.isChannelFree ?? true else { return .skipped(.channelBusy) }

        requestsThisRoute += 1
        let outcome = await service.describeEnvironment(trigger: .auto, preCapturedFrame: frame)
        record(outcome, signature: signature)
        return .requested(outcome)
    }

    // MARK: Resultado

    private var effectiveMinInterval: TimeInterval {
        isLowPowerMode()
            ? configuration.minInterval * configuration.lowPowerMultiplier
            : configuration.minInterval
    }

    private func record(_ outcome: EnvironmentNarrationOutcome, signature: SceneSignature) {
        switch outcome {
        case .described:
            baseline = signature
            consecutiveFailures = 0
            backoffUntil = nil
        case .unavailable:
            // 429, 5xx, timeout, respuesta vieja o sin red: se espera cada vez más antes de
            // volver a intentar, sin avisar. La escena de referencia no cambia.
            consecutiveFailures += 1
            backoffUntil = now().addingTimeInterval(
                configuration.backoff(afterFailures: consecutiveFailures)
            )
        case .consentRequired, .alreadyDescribing, .cancelled, .repeated:
            break
        }
    }
}
