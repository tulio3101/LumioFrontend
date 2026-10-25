import Foundation

struct AudioPolicy: AudioPolicyEvaluating {
    func shouldInterrupt(
        current: AudioMessage, incoming: AudioMessage, context: AudioDecisionContext
    ) -> Bool {
        switch incoming.priority {
        case .immediateRisk:
            return current.priority != .immediateRisk
        case .routeInformation:
            return current.priority == .environmentInformation
                && context.urgentNavigationMessageIDs.contains(incoming.id)
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
