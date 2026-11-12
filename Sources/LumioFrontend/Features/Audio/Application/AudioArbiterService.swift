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
    private var completionWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
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

    /// Espera a que la explicación termine. No abre diálogos sobre una locución pendiente.
    /// P1 puede interrumpir P2; el árbitro lo reanuda según su política habitual.
    func receiveAndWait(_ message: AudioMessage) async -> Bool {
        guard !Task.isCancelled, message.status == .pending,
              current?.message.id != message.id,
              !queue.entries.contains(where: { $0.message.id == message.id }),
              completionWaiters[message.id] == nil else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completionWaiters[message.id] = continuation
                receive(message)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaitingMessage(message.id) }
        }
    }

    private func cancelWaitingMessage(_ id: UUID) {
        completionWaiters.removeValue(forKey: id)?.resume(returning: false)
        let removed = queue.removeIrrelevant { $0.id != id }
        for message in removed { publish(message, status: .discarded) }
        if current?.message.id == id {
            let message = current!.message
            current = nil
            token = nil
            player.stop()
            publish(message, status: .discarded)
        }
        processNext()
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
        // Obsolescencia por captura: cualquier mensaje con captureSequence (p. ej. las alertas
        // de obstáculo, incluidas las immediateRisk) se descarta si su captura es más vieja que
        // la última procesada de su contexto. Los avisos de sistema no llevan captureSequence,
        // así que nunca se descartan por esto.
        if let contextID = message.contextID, let sequence = message.captureSequence,
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
        if let contextID = message.contextID, let sequence = message.captureSequence {
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

    func cancel(contextIDs: Set<String>) {
        guard !contextIDs.isEmpty else { return }
        let removed = queue.removeIrrelevant { message in
            message.contextID.map { !contextIDs.contains($0) } ?? true
        }
        for message in removed { publish(message, status: .discarded) }
        if let active = current, let contextID = active.message.contextID, contextIDs.contains(contextID) {
            // Invalidar el token antes de stop: el callback de la cancelación es antiguo.
            current = nil
            token = nil
            player.stop()
            publish(active.message, status: .discarded)
        }
        processNext()
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
        if status == .completed || status == .discarded {
            completionWaiters.removeValue(forKey: message.id)?.resume(returning: status == .completed)
        }
        onMessageChanged?(message)
    }
}
