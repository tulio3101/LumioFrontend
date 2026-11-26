import Foundation

struct AudioPolicy: AudioPolicyEvaluating {
    var speech = SpeechDurationEstimator()

    /// SCRUM-42/44 (spike SCRUM-309):
    /// - P1 interrumpe P2 y P3 siempre.
    /// - P2 interrumpe P3 solo si es urgente: el productor lo marcó en el contexto o, con
    ///   `turnDeadline`, esperar a que termine la narración dejaría ≤ 1,5 s (giro cerrado) o
    ///   ≤ 2,5 s (amplio) para el giro. Si hay tiempo, espera.
    /// - P3 nunca interrumpe.
    func shouldInterrupt(
        current: AudioMessage, startedAt: Date, incoming: AudioMessage,
        context: AudioDecisionContext, now: Date
    ) -> Bool {
        switch incoming.priority {
        case .immediateRisk:
            return current.priority != .immediateRisk
        case .routeInformation:
            guard current.priority == .environmentInformation else { return false }
            if context.urgentNavigationMessageIDs.contains(incoming.id) { return true }
            guard let deadline = incoming.turnDeadline else { return false }
            let waiting = speech.remaining(of: current, startedAt: startedAt, now: now)
            return deadline.requiresInterruption(waiting: waiting, now: now)
        case .environmentInformation:
            return false
        }
    }

    func isRelevant(_ message: AudioMessage, context: AudioDecisionContext, now: Date) -> Bool {
        guard !message.isExpired(at: now) else { return false }
        if let id = message.contextID, context.invalidatedContextIDs.contains(id) {
            return false
        }
        return true
    }
}
