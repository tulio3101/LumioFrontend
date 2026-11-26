import Foundation
import Testing
@testable import LumioFrontend

// SCRUM-324: Consentir el Envío de Imágenes para la Narración.

private final class MemoryConsentStore: NarrationConsentStoring {
    var consent: NarrationConsent?
    var failSave = false
    var failLoad = false
    init(_ consent: NarrationConsent? = nil) { self.consent = consent }
    func load() throws -> NarrationConsent? {
        if failLoad { throw CocoaError(.fileReadCorruptFile) }
        return consent
    }
    func save(_ consent: NarrationConsent) throws {
        if failSave { throw CocoaError(.fileWriteNoPermission) }
        self.consent = consent
    }
}

@MainActor
private final class ConsentArbiter: AudioArbitrating {
    private(set) var received: [AudioMessage] = []
    private(set) var cancelled: [Set<String>] = []
    func receive(_ message: AudioMessage) { received.append(message) }
    func processNext() {}
    func playbackFinished(token: PlaybackToken) {}
    func discardIrrelevant() {}
    func resetSession() {}
    func updateContext(_ context: AudioDecisionContext) {}
    func cancel(contextIDs: Set<String>) { cancelled.append(contextIDs) }
}

private let decidedAt = Date(timeIntervalSince1970: 1_800_000_000)

private func consent(_ granted: Bool, version: String = NarrationConsentPolicy.currentVersion) -> NarrationConsent {
    NarrationConsent(granted: granted, version: version, decidedAt: decidedAt)
}

@MainActor
private func makeService(_ store: MemoryConsentStore) -> (NarrationConsentService, ConsentArbiter) {
    let arbiter = ConsentArbiter()
    return (NarrationConsentService(store: store, arbiter: arbiter, now: { decidedAt }), arbiter)
}

// MARK: Sin consentimiento no se envía nada

@Test @MainActor func withoutConsentNothingIsUploaded() {
    let (service, _) = makeService(MemoryConsentStore())
    #expect(service.status == .notAsked)
    #expect(service.consentVersionForUpload == nil)
}

@Test @MainActor func declinedConsentNeverUploads() {
    let (service, _) = makeService(MemoryConsentStore(consent(false)))
    #expect(service.status == .declined)
    #expect(service.consentVersionForUpload == nil)
}

@Test @MainActor func anUnreadableFileIsTreatedAsNotAsked() {
    let store = MemoryConsentStore(consent(true))
    store.failLoad = true
    let (service, _) = makeService(store)
    #expect(service.status == .notAsked)
    #expect(service.consentVersionForUpload == nil)
}

// MARK: Explicación y consentimiento explícito

@Test @MainActor func explanationIsSpokenBeforeTheFirstNarration() {
    let (service, arbiter) = makeService(MemoryConsentStore())
    #expect(!service.requireConsentBeforeNarration())
    let spoken = arbiter.received.last
    #expect(spoken?.text.contains("Amazon Web Services") == true)
    #expect(spoken?.text.contains("no guarda") == true)
    #expect(spoken?.text.contains("prevenir abusos") == true)
    #expect(spoken?.text.hasSuffix(NarrationConsentPolicy.question) == true)
    // P2: se oye, pero una alerta de seguridad lo interrumpe.
    #expect(spoken?.priority == .routeInformation)
    #expect(spoken?.contextID == NarrationConsentService.contextID)
}

@Test @MainActor func acceptingIsExplicitStoredAndAnnounced() {
    let store = MemoryConsentStore()
    let (service, arbiter) = makeService(store)
    #expect(service.accept())
    #expect(store.consent == consent(true))
    #expect(service.status == .granted)
    #expect(service.consentVersionForUpload == NarrationConsentPolicy.currentVersion)
    #expect(service.requireConsentBeforeNarration())
    #expect(arbiter.received.last?.text == NarrationConsentPolicy.accepted)
}

@Test @MainActor func decliningKeepsTheRestOfTheAppWorking() {
    let store = MemoryConsentStore()
    let (service, arbiter) = makeService(store)
    #expect(service.decline())
    #expect(store.consent == consent(false))
    #expect(service.consentVersionForUpload == nil)
    #expect(arbiter.received.last?.text == NarrationConsentPolicy.declined)
    // Pedir una narración después solo recuerda dónde activarla.
    #expect(!service.requireConsentBeforeNarration())
    #expect(arbiter.received.last?.text == NarrationConsentPolicy.required)
}

// MARK: Revocar

@Test @MainActor func revokingStopsNarrationAndCancelsTheRequestInFlight() {
    let store = MemoryConsentStore(consent(true))
    let (service, arbiter) = makeService(store)
    var revoked = 0
    service.onRevoked = { revoked += 1 }
    #expect(service.revoke())
    #expect(service.status == .declined)
    #expect(store.consent?.granted == false)
    #expect(service.consentVersionForUpload == nil)
    #expect(arbiter.cancelled.contains([NarrationAudio.contextID]))
    #expect(revoked == 1)
    #expect(arbiter.received.last?.text == NarrationConsentPolicy.revoked)
}

@Test @MainActor func failingToSaveKeepsThePreviousDecisionAndSaysSo() {
    let store = MemoryConsentStore(consent(true))
    store.failSave = true
    let (service, arbiter) = makeService(store)
    var revoked = 0
    service.onRevoked = { revoked += 1 }
    #expect(!service.revoke())
    #expect(service.status == .granted)
    #expect(revoked == 0)
    #expect(arbiter.received.last?.text == NarrationConsentPolicy.saveFailed)
}

// MARK: Se conserva entre sesiones y se versiona

@Test @MainActor func decisionSurvivesClosingTheApp() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("narration-consent.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let first = NarrationConsentService(store: FileNarrationConsentStore(fileURL: url), arbiter: nil, now: { decidedAt })
    #expect(first.accept())
    let reopened = NarrationConsentService(store: FileNarrationConsentStore(fileURL: url), arbiter: nil)
    #expect(reopened.status == .granted)
    #expect(try FileNarrationConsentStore(fileURL: url).load() == consent(true))
}

@Test @MainActor func aNewNoticeVersionAsksAgain() {
    let (service, arbiter) = makeService(MemoryConsentStore(consent(true, version: "2025-01-1")))
    #expect(service.status == .outdated)
    #expect(service.consentVersionForUpload == nil)
    #expect(!service.requireConsentBeforeNarration())
    #expect(arbiter.received.last?.text.contains(NarrationConsentPolicy.question) == true)
}

@Test func statusFollowsTheStoredDecision() {
    #expect(NarrationConsentPolicy.status(of: nil) == .notAsked)
    #expect(NarrationConsentPolicy.status(of: consent(true)) == .granted)
    #expect(NarrationConsentPolicy.status(of: consent(false)) == .declined)
    #expect(NarrationConsentPolicy.status(of: consent(true, version: "0")) == .outdated)
    #expect(NarrationConsentPolicy.status(of: consent(false, version: "0")) == .declined)
}
