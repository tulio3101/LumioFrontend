import Foundation

@MainActor
final class AudioArbiterService: AudioArbitrating {
    private let player: any AudioPlaying
    private let policy: any AudioPolicyEvaluating
    private let now: () -> Date
    private var queue = AudioMessageQueue()
    private var current: AudioMessageQueue.Entry?
    private var token: PlaybackToken?
    private var context = AudioDecisionContext()
    private let deduplication = AudioDeduplicationPolicy()
    private var latestCaptureByContext: [String: UInt64] = [:]

    var currentMessage: AudioMessage? { current?.message }
    var pendingMessages: [AudioMessage] {
        queue.entries.sorted { $0.sequence < $1.sequence }.map(\.message)
    }
    /// Permite observar transiciones sin guardar un historial ilimitado en memoria.
    var onMessageChanged: ((AudioMessage) -> Void)?
    var onPlaybackError: ((UUID, Error) -> Void)?

    init(
        player: any AudioPlaying,
        policy: any AudioPolicyEvaluating = AudioPolicy(),
        now: @escaping () -> Date = Date.init
    ) {
        self.player = player
        self.policy = policy
        self.now = now
        player.onFinished = { [weak self] token in
            self?.playbackFinished(token: token)
        }
    }

    func receive(_ message: AudioMessage) {
        guard message.status == .pending,
              current?.message.id != message.id,
              !queue.entries.contains(where: { $0.message.id == message.id }) else { return }
        guard policy.isRelevant(message, context: context, now: now()) else {
            publish(message, status: .discarded)
            return
        }
        // Limpiar pendientes vencidos antes de usarlos como referencia de duplicidad.
        discardIrrelevant()
        if message.priority == .environmentInformation,
           let contextID = message.contextID, let sequence = message.captureSequence,
           let latest = latestCaptureByContext[contextID], sequence < latest {
            publish(message, status: .discarded)
            return
        }
        let candidates = queue.entries.map(\.message) + (current.map { [$0.message] } ?? [])
        if candidates.contains(where: {
            policy.isRelevant($0, context: context, now: now())
                && deduplication.isDuplicate(message, of: $0)
        }) {
            publish(message, status: .discarded)
            return
        }
        let replaced = queue.removeIrrelevant {
            !deduplication.isNewerCapture(message, than: $0)
        }
        if message.priority == .environmentInformation,
           let contextID = message.contextID, let sequence = message.captureSequence {
            latestCaptureByContext[contextID] = sequence
        }
        queue.append(message)
        for old in replaced { publish(old, status: .discarded) }
        processNext()
    }

    func updateContext(_ context: AudioDecisionContext) {
        self.context = context
        for id in context.invalidatedContextIDs {
            latestCaptureByContext.removeValue(forKey: id)
        }
        processNext()
    }

    /// Cerrar el trayecto: detener audio y liberar cola, contexto e historial de capturas.
    func resetSession() {
        let messages = queue.entries.map(\.message) + (current.map { [$0.message] } ?? [])
        token = nil
        current = nil
        queue = AudioMessageQueue()
        context = AudioDecisionContext()
        latestCaptureByContext.removeAll()
        player.stop()
        for message in messages { publish(message, status: .discarded) }
    }

    func discardIrrelevant() {
        let timestamp = now()
        let discarded = queue.removeIrrelevant {
            policy.isRelevant($0, context: context, now: timestamp)
        }
        for message in discarded { publish(message, status: .discarded) }
    }

    func processNext() {
        discardIrrelevant()
        if let active = current {
            guard let incoming = queue.popNext(where: {
                policy.shouldInterrupt(current: active.message, incoming: $0, context: context)
            }) else { return }
            // Invalidar el token antes de stop: un callback de cancelación es antiguo.
            current = nil
            token = nil
            player.stop()
            if active.message.priority == .routeInformation,
               policy.isRelevant(active.message, context: context, now: now()) {
                var pending = active
                pending.message.status = .pending
                queue.restore(pending)
                onMessageChanged?(pending.message)
            } else {
                publish(active.message, status: .discarded)
            }
            queue.restore(incoming)
        }

        while current == nil, var next = queue.popNext() {
            next.message.status = .playing
            let attempt = PlaybackToken()
            current = next
            token = attempt
            onMessageChanged?(next.message)
            do {
                try player.play(next.message, token: attempt)
            } catch {
                // Un error de inicio no deja ocupada la cola ni bloquea alertas futuras.
                if token == attempt {
                    current = nil
                    token = nil
                    publish(next.message, status: .discarded)
                }
                onPlaybackError?(next.message.id, error)
            }
        }
    }

    func playbackFinished(token finished: PlaybackToken) {
        guard token == finished, let active = current else { return }
        current = nil
        token = nil
        publish(active.message, status: .completed)
        processNext()
    }

    private func publish(_ original: AudioMessage, status: AudioMessageStatus) {
        var message = original
        message.status = status
        onMessageChanged?(message)
    }
}
