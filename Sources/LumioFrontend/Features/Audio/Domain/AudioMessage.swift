import Foundation

enum AudioPriority: Int, CaseIterable {
    case immediateRisk = 1
    case routeInformation = 2
    case environmentInformation = 3
}

enum AudioMessageStatus {
    case pending, playing, completed, discarded
}

struct AudioMessage: Identifiable {
    let id: UUID
    let text: String
    let priority: AudioPriority
    let createdAt: Date
    let expiresAt: Date?
    let contextID: String?
    let deduplicationKey: String?
    let captureSequence: UInt64?
    var status: AudioMessageStatus = .pending

    init(
        id: UUID = UUID(), text: String, priority: AudioPriority,
        createdAt: Date = Date(), expiresAt: Date? = nil, contextID: String? = nil,
        deduplicationKey: String? = nil, captureSequence: UInt64? = nil
    ) {
        self.id = id
        self.text = text
        self.priority = priority
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.contextID = contextID
        self.deduplicationKey = deduplicationKey
        self.captureSequence = captureSequence
    }

    func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }
}
