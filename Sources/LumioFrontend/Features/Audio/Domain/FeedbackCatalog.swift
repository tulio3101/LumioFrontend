import Foundation

/// SCRUM-31: un solo catálogo de avisos de sistema (audio + háptica). El texto se reutiliza de
/// los anuncios que ya existen; la prioridad la decide el AudioArbiter y el patrón el motor
/// háptico. Nada de TTS ni `UINotificationFeedbackGenerator` fuera de esos dos.
///
/// La matriz completa (evento → prioridad → patrón) está en
/// `docs/HU-recibir-retroalimentacion-del-sistema.md`. Prioridades: 1 seguridad
/// (`.immediateRisk`), 2 navegación y avisos del sistema (`.routeInformation`), 3 narración e
/// información (`.environmentInformation`). La cola, la interrupción y la reproducción son del
/// árbitro (SCRUM-42): el catálogo solo dice qué suena y con qué prioridad.
struct FeedbackItem {
    let message: AudioMessage
    let haptic: HapticCue?
}

enum FeedbackEvent: Equatable {
    case routeCreated(ActiveRoute)
    case routeModified(ActiveRoute)
    case routeRecalculated(ActiveRoute)
    case routeFinished(RouteFinishResult)
    case arrival(RouteFinishResult)
    /// No se pudo crear la ruta (SCRUM-201: error de una acción).
    case routeCreationFailed(RouteCreationError)
    /// No se pudo cambiar el destino; la ruta anterior, si había, sigue activa.
    case routeModificationFailed(RouteCreationError, keeping: ActiveRoute?)
    /// No se pudo recalcular la ruta tras un desvío o a pedido.
    case rerouteFailed(RouteCreationError, destination: String)
    case permissionsDenied
    case modelUnavailable
    case lowLight
    case lowLightRecovered
    /// SCRUM-321: la detección se pausa por calor crítico (P1) y se reanuda (P2).
    case thermalPaused
    case thermalResumed
    /// SCRUM-37: la detección volvió tras una caída del modelo.
    case detectionRecovered
    case reducedMode
    case fullMode
    case offline(destination: String?)
    case backendError
    case sessionClosed
    case sessionExpired
    /// SCRUM-41: cae / vuelve la narración (P2, una vez por transición).
    case narrationUnavailable(NarrationOutage)
    case narrationAvailable
    /// Botón de Emergencia: todo es P1 (lo que el usuario pidió en una emergencia pasa por
    /// delante de la navegación) en el contexto `emergency`.
    case emergencyActivated(seconds: Int)
    case emergencyCountdown(Int)
    case emergencyCancelled
    case emergencySending
    case emergencySent(EmergencyDelivery)
    case emergencyFailed(EmergencyFailure)
}

enum FeedbackCatalog {
    private static let instructions = NavigationInstructionBuilder()

    static func item(for event: FeedbackEvent, now: Date = Date()) -> FeedbackItem {
        switch event {
        case .routeCreated(let route):
            return FeedbackItem(message: instructions.readyMessage(for: route, now: now), haptic: .routeReady)
        case .routeModified(let route):
            return FeedbackItem(message: instructions.updatedMessage(for: route, now: now), haptic: .routeReady)
        case .routeRecalculated(let route):
            return FeedbackItem(message: instructions.reroutedMessage(for: route, now: now), haptic: .routeReady)
        case .routeFinished(let result):
            return finish(result, now: now)
        case .arrival(let result):
            return finish(result, now: now)
        case .routeCreationFailed(let failure):
            return FeedbackItem(message: instructions.failureMessage(failure, now: now), haptic: .routeFailed)
        case .routeModificationFailed(let failure, let route):
            return FeedbackItem(
                message: instructions.modificationFailureMessage(failure, keeping: route, now: now),
                haptic: .routeFailed
            )
        case .rerouteFailed(let failure, let destination):
            return FeedbackItem(
                message: instructions.rerouteNotice(
                    RerouteAnnouncements.failure(failure, destination: destination),
                    key: "failure-\(failure)",
                    now: now
                ),
                haptic: .routeFailed
            )
        case .permissionsDenied:
            return FeedbackItem(message: SafetyAudio.cameraUnavailable(), haptic: nil)
        case .modelUnavailable:
            return FeedbackItem(message: SafetyAudio.modelUnavailable(), haptic: nil)
        case .lowLight:
            return FeedbackItem(
                message: AudioMessage(
                    text: "Poca luz. Avanza con precaución.",
                    priority: .immediateRisk,
                    createdAt: now,
                    contextID: SafetyAudio.context,
                    deduplicationKey: "low-light-alert"
                ),
                haptic: .warning
            )
        case .lowLightRecovered:
            return FeedbackItem(
                message: AudioMessage(
                    text: "Luz suficiente de nuevo.",
                    priority: .environmentInformation,
                    createdAt: now,
                    contextID: SafetyAudio.context,
                    deduplicationKey: "low-light-recovered"
                ),
                haptic: nil
            )
        case .thermalPaused:
            return FeedbackItem(message: SafetyAudio.thermalPaused(), haptic: .warning)
        case .thermalResumed:
            return FeedbackItem(message: SafetyAudio.thermalResumed(), haptic: nil)
        case .detectionRecovered:
            return FeedbackItem(message: SafetyAudio.detectionRecovered(now: now), haptic: nil)
        case .reducedMode:
            return FeedbackItem(message: SafetyAudio.reducedMode(now: now), haptic: .safetyReady)
        case .fullMode:
            return FeedbackItem(message: SafetyAudio.fullMode(now: now), haptic: .safetyReady)
        case .offline(let destination):
            if let destination {
                return FeedbackItem(
                    message: instructions.rerouteNotice(
                        RerouteAnnouncements.offline(destination: destination),
                        key: "offline",
                        now: now
                    ),
                    haptic: nil
                )
            }
            return FeedbackItem(
                message: AudioMessage(
                    text: "Sin conexión.",
                    priority: .environmentInformation,
                    createdAt: now,
                    contextID: "connectivity",
                    deduplicationKey: "offline"
                ),
                haptic: nil
            )
        case .backendError:
            return FeedbackItem(
                message: instructions.failureMessage(.serviceUnavailable, now: now),
                haptic: .routeFailed
            )
        case .sessionClosed:
            return FeedbackItem(message: SessionAudio.closed(), haptic: nil)
        case .sessionExpired:
            return FeedbackItem(message: SessionAudio.expiredRouteContinues(), haptic: nil)
        case .narrationUnavailable(let outage):
            // Aviso del sistema (P2): el usuario debe saber que no habrá descripciones. Va en el
            // contexto de estado de la narración, no en el de las descripciones, para que una
            // descripción nueva no lo cancele.
            return FeedbackItem(
                message: AudioMessage(
                    text: EnvironmentNarrationMessages.outage(outage),
                    priority: .routeInformation,
                    createdAt: now,
                    expiresAt: now.addingTimeInterval(10),
                    contextID: NarrationAudio.statusContextID,
                    deduplicationKey: "narration-unavailable"
                ),
                haptic: .narrationUnavailable
            )
        case .narrationAvailable:
            return FeedbackItem(
                message: AudioMessage(
                    text: EnvironmentNarrationMessages.available,
                    priority: .routeInformation,
                    createdAt: now,
                    expiresAt: now.addingTimeInterval(10),
                    contextID: NarrationAudio.statusContextID,
                    deduplicationKey: "narration-available"
                ),
                haptic: .narrationAvailable
            )
        case .emergencyActivated(let seconds):
            return emergency(EmergencyAnnouncements.activated(seconds: seconds), .emergencyActivated, now: now)
        case .emergencyCountdown(let seconds):
            return emergency(EmergencyAnnouncements.countdown(seconds), nil, now: now)
        case .emergencyCancelled:
            return emergency(EmergencyAnnouncements.cancelled, nil, now: now)
        case .emergencySending:
            return emergency(EmergencyAnnouncements.sending, nil, now: now)
        case .emergencySent(let delivery):
            return emergency(EmergencyAnnouncements.sent(delivery), .emergencySent, now: now)
        case .emergencyFailed(let failure):
            return emergency(EmergencyAnnouncements.failed(failure), .emergencyFailed, now: now)
        }
    }

    /// Reproduce el aviso por el árbitro y, si hay patrón, por el motor háptico.
    @MainActor
    static func emit(
        _ event: FeedbackEvent,
        audio: (any AudioArbitrating)?,
        haptics: (any HapticFeedbackPlaying)? = nil,
        now: Date = Date()
    ) {
        let item = Self.item(for: event, now: now)
        audio?.receive(item.message)
        if let cue = item.haptic {
            haptics?.play(cue)
        }
    }

    private static func emergency(_ text: String, _ haptic: HapticCue?, now: Date) -> FeedbackItem {
        FeedbackItem(
            message: AudioMessage(
                text: text,
                priority: .immediateRisk,
                createdAt: now,
                contextID: EmergencyService.contextID
            ),
            haptic: haptic
        )
    }

    private static func finish(_ result: RouteFinishResult, now: Date) -> FeedbackItem {
        FeedbackItem(
            message: AudioMessage(
                text: RouteFinishAnnouncements.finished(result),
                priority: .routeInformation,
                createdAt: now,
                contextID: RouteFinishService.contextID,
                deduplicationKey: "finished-\(result.finished.route.id.uuidString)"
            ),
            haptic: .routeFinished
        )
    }
}
