import Foundation

/// SCRUM-31: un solo catálogo de avisos de sistema (audio + háptica). El texto se reutiliza de
/// los anuncios que ya existen; la prioridad la decide el AudioArbiter y el patrón el motor
/// háptico. Nada de TTS ni `UINotificationFeedbackGenerator` fuera de esos dos.
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
    case permissionsDenied
    case modelUnavailable
    case lowLight
    case lowLightRecovered
    case reducedMode
    case fullMode
    case offline(destination: String?)
    case backendError
    case sessionClosed
    case sessionExpired
    /// SCRUM-41: cae / vuelve la narración (P2, una vez por transición).
    case narrationUnavailable(NarrationOutage)
    case narrationAvailable
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
