/// Compara identidad de evento, nunca similitud del texto.
struct AudioDeduplicationPolicy {
    func isNewerCapture(_ incoming: AudioMessage, than existing: AudioMessage) -> Bool {
        guard incoming.priority == .environmentInformation,
              existing.priority == .environmentInformation,
              let context = incoming.contextID, context == existing.contextID,
              let incomingSequence = incoming.captureSequence,
              let existingSequence = existing.captureSequence else { return false }
        return incomingSequence > existingSequence
    }

    func isDuplicate(_ incoming: AudioMessage, of existing: AudioMessage) -> Bool {
        guard incoming.priority != .immediateRisk,
              incoming.priority == existing.priority,
              let key = incoming.deduplicationKey, !key.isEmpty,
              let context = incoming.contextID, !context.isEmpty,
              key == existing.deduplicationKey, context == existing.contextID else { return false }
        // Una captura reciente tiene precedencia incluso si repite la clave.
        return !isNewerCapture(incoming, than: existing)
    }
}
