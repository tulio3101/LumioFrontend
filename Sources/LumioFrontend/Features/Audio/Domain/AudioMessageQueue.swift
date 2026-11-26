/// Conserva el orden de recepción, incluso si vuelve un P2 interrumpido.
struct AudioMessageQueue {
    struct Entry {
        var message: AudioMessage
        let sequence: UInt64
    }

    private(set) var entries: [Entry] = []
    private var nextSequence: UInt64 = 0

    mutating func append(_ message: AudioMessage) {
        entries.append(Entry(message: message, sequence: nextSequence))
        nextSequence += 1
    }

    mutating func restore(_ entry: Entry) {
        entries.append(entry)
    }

    mutating func popNext(where eligible: (AudioMessage) -> Bool = { _ in true }) -> Entry? {
        let index = entries.indices.filter { eligible(entries[$0].message) }.min { a, b in
            let lhs = entries[a]
            let rhs = entries[b]
            if lhs.message.priority.rawValue == rhs.message.priority.rawValue {
                return lhs.sequence < rhs.sequence
            }
            return lhs.message.priority.rawValue < rhs.message.priority.rawValue
        }
        guard let index else { return nil }
        return entries.remove(at: index)
    }

    mutating func removeIrrelevant(_ isRelevant: (AudioMessage) -> Bool) -> [AudioMessage] {
        let discarded = entries.filter { !isRelevant($0.message) }.map(\.message)
        entries.removeAll { !isRelevant($0.message) }
        return discarded
    }
}
