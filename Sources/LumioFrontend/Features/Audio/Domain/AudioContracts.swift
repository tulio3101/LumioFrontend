import Foundation

/// Un token nuevo por intento: distingue callbacks de un P2 detenido y reiniciado.
struct PlaybackToken: Hashable {
    let rawValue: UUID

    init() { rawValue = UUID() }
}

@MainActor
protocol AudioPlaying: AnyObject {
    var onFinished: ((PlaybackToken) -> Void)? { get set }
    func play(_ message: AudioMessage, token: PlaybackToken) throws
    func stop()
}

@MainActor
protocol AudioArbitrating: AnyObject {
    func receive(_ message: AudioMessage)
    func processNext()
    func playbackFinished(token: PlaybackToken)
    func discardIrrelevant()
    func resetSession()
    func updateContext(_ context: AudioDecisionContext)
    /// Corta ya los mensajes de esos contextos: el que suena y los pendientes (por ejemplo,
    /// las indicaciones de una ruta que se finalizó). Los demás mensajes siguen.
    func cancel(contextIDs: Set<String>)
}

/// El productor proporciona el contexto; todavía no se fijan umbrales de giro.
struct AudioDecisionContext {
    var urgentNavigationMessageIDs: Set<UUID> = []
    var invalidatedContextIDs: Set<String> = []
}

protocol AudioPolicyEvaluating {
    func shouldInterrupt(
        current: AudioMessage, incoming: AudioMessage, context: AudioDecisionContext
    ) -> Bool
    func isRelevant(_ message: AudioMessage, context: AudioDecisionContext, now: Date) -> Bool
}
