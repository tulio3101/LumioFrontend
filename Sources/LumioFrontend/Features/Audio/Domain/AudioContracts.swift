import Foundation

/// Un token nuevo por intento: distingue callbacks de un P2 detenido y reiniciado.
struct PlaybackToken: Hashable {
    let rawValue: UUID

    init() { rawValue = UUID() }
}

/// SCRUM-44: cómo empieza una locución. Tras cortar una narración para dar una indicación,
/// el reproductor deja una pausa breve para que el cambio se note y no suene como una sola
/// frase. Una alerta P1 nunca espera: empieza siempre `.immediate`.
enum AudioTransition: Equatable {
    case immediate
    case afterInterruption
}

@MainActor
protocol AudioPlaying: AnyObject {
    var onFinished: ((PlaybackToken) -> Void)? { get set }
    func play(_ message: AudioMessage, token: PlaybackToken) throws
    func play(_ message: AudioMessage, token: PlaybackToken, transition: AudioTransition) throws
    func stop()
}

extension AudioPlaying {
    /// Los reproductores que no distinguen la transición (pruebas) empiezan igual.
    func play(_ message: AudioMessage, token: PlaybackToken, transition: AudioTransition) throws {
        try play(message, token: token)
    }
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
    /// `startedAt`: cuándo empezó a sonar `current`, para estimar cuánto le falta.
    func shouldInterrupt(
        current: AudioMessage, startedAt: Date, incoming: AudioMessage,
        context: AudioDecisionContext, now: Date
    ) -> Bool
    func isRelevant(_ message: AudioMessage, context: AudioDecisionContext, now: Date) -> Bool
}
