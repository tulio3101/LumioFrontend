import Foundation
import Testing
@testable import LumioFrontend

// SCRUM-39: Solicitar Narración del Entorno. Mecanismos de solicitud y solicitudes repetidas
// sin procesamiento innecesario. La captura, el envío y las fallas son de SCRUM-38.

private let start = Date(timeIntervalSince1970: 1_900_000_000)

@MainActor
private final class Clock {
    var now = start
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Cada foto lleva un byte que dice qué escena muestra (1 = la calle, 2 = otra calle…).
@MainActor
private final class SceneCapturer: NarrationFrameCapturing {
    let clock: Clock
    var scene: UInt8 = 1
    private(set) var calls = 0
    init(clock: Clock) { self.clock = clock }
    func captureNarrationFrame() async -> NarrationCapture {
        calls += 1
        return .frame(NarrationFrame(jpeg: Data([0xFF, 0xD8, scene, 0xFF, 0xD9]), capturedAt: clock.now))
    }
}

/// Huella según la escena: la misma escena da la misma huella; otra, una ortogonal.
private struct SceneSignatures: SceneSignatureProviding {
    func signature(for jpeg: Data) -> SceneSignature? {
        guard jpeg.count > 2 else { return nil }
        var vector = [Float](repeating: 0, count: 8)
        vector[Int(jpeg[2]) % 8] = 1
        return SceneSignature(vector)
    }
}

private final class CountingDescriber: EnvironmentDescribing, @unchecked Sendable {
    private(set) var requests = 0
    func describe(_ frame: NarrationFrame, trigger: NarrationTrigger, consentVersion: String) async throws -> String {
        requests += 1
        return "Descripción \(requests)."
    }
}

@MainActor
private final class GrantedConsent: NarrationConsentGating {
    var consentVersionForUpload: String? { NarrationConsentPolicy.currentVersion }
    func requireConsentBeforeNarration() -> Bool { true }
}

@MainActor
private final class Arbiter: AudioArbitrating {
    private(set) var received: [AudioMessage] = []
    func receive(_ message: AudioMessage) { received.append(message) }
    func processNext() {}
    func playbackFinished(token: PlaybackToken) {}
    func discardIrrelevant() {}
    func resetSession() {}
    func updateContext(_ context: AudioDecisionContext) {}
    func cancel(contextIDs: Set<String>) {}
    var narrations: [AudioMessage] { received.filter { $0.contextID == NarrationAudio.contextID } }
}

@MainActor
private struct Harness {
    let clock = Clock()
    let capturer: SceneCapturer
    let describer = CountingDescriber()
    let arbiter = Arbiter()
    let service: EnvironmentNarrationService

    init(signatures: (any SceneSignatureProviding)? = SceneSignatures()) {
        capturer = SceneCapturer(clock: clock)
        let clock = clock
        service = EnvironmentNarrationService(
            capturer: capturer, describer: describer, consent: GrantedConsent(),
            connectivity: FakeConnectivity(), arbiter: arbiter, signatures: signatures,
            sleep: { _ in try await Task.sleep(nanoseconds: 60 * 1_000_000_000) },
            now: { clock.now }
        )
    }
}

// MARK: Solicitudes repetidas

@Test @MainActor func askingAgainRightAwayRepeatsWithoutAPhoto() async {
    let h = Harness()
    #expect(await h.service.describeEnvironment() == .described("Descripción 1."))
    h.clock.advance(2)
    #expect(await h.service.describeEnvironment() == .repeated("Descripción 1."))
    #expect(h.capturer.calls == 1)
    #expect(h.describer.requests == 1)
    // Se repite por audio como una narración más (P3, no interrumpe alertas).
    let replay = h.arbiter.narrations.last
    #expect(replay?.text == EnvironmentNarrationMessages.repeated("Descripción 1."))
    #expect(replay?.priority == .environmentInformation)
}

@Test @MainActor func sameSceneShortlyAfterIsRepeatedWithoutSending() async {
    let h = Harness()
    _ = await h.service.describeEnvironment()
    h.clock.advance(6)
    #expect(await h.service.describeEnvironment() == .repeated("Descripción 1."))
    // Se tomó la foto para comparar, pero no se envió.
    #expect(h.capturer.calls == 2)
    #expect(h.describer.requests == 1)
}

@Test @MainActor func aNewSceneIsAlwaysDescribed() async {
    let h = Harness()
    _ = await h.service.describeEnvironment()
    h.clock.advance(6)
    h.capturer.scene = 2
    #expect(await h.service.describeEnvironment() == .described("Descripción 2."))
    #expect(h.describer.requests == 2)
}

@Test @MainActor func afterAWhileTheSameSceneIsDescribedAgain() async {
    let h = Harness()
    _ = await h.service.describeEnvironment()
    h.clock.advance(NarrationRepeatPolicy().sameSceneWindow)
    #expect(await h.service.describeEnvironment() == .described("Descripción 2."))
}

@Test @MainActor func withoutSceneSignaturesOnlyTheShortWindowRepeats() async {
    let h = Harness(signatures: nil)
    _ = await h.service.describeEnvironment()
    h.clock.advance(6)
    #expect(await h.service.describeEnvironment() == .described("Descripción 2."))
}

@Test @MainActor func automaticUpdatesNeverReplay() async {
    let h = Harness()
    _ = await h.service.describeEnvironment()
    h.clock.advance(1)
    let frame = NarrationFrame(jpeg: Data([0xFF, 0xD8, 1, 0xFF, 0xD9]), capturedAt: h.clock.now)
    #expect(await h.service.describeEnvironment(trigger: .auto, preCapturedFrame: frame) == .described("Descripción 2."))
}

@Test @MainActor func revokingConsentForgetsTheLastDescription() async {
    let h = Harness()
    _ = await h.service.describeEnvironment()
    h.service.cancel()
    h.clock.advance(1)
    #expect(await h.service.describeEnvironment() == .described("Descripción 2."))
}

@Test @MainActor func aSecondRequestWhileDescribingIsAnnounced() async {
    let h = Harness()
    h.service.requestDescription()
    h.service.requestDescription()
    #expect(h.arbiter.received.contains { $0.text == EnvironmentNarrationMessages.alreadyDescribing })
}

@Test func repeatPolicyWindows() {
    let policy = NarrationRepeatPolicy()
    let same = SceneSignature([1, 0])
    let other = SceneSignature([0, 1])
    #expect(policy.replaysWithoutPhoto(lastCapturedAt: start, now: start.addingTimeInterval(2.9)))
    #expect(!policy.replaysWithoutPhoto(lastCapturedAt: start, now: start.addingTimeInterval(3)))
    #expect(policy.replaysSameScene(last: same, lastCapturedAt: start, current: same, now: start.addingTimeInterval(9)))
    #expect(!policy.replaysSameScene(last: same, lastCapturedAt: start, current: other, now: start.addingTimeInterval(9)))
    #expect(!policy.replaysSameScene(last: same, lastCapturedAt: start, current: same, now: start.addingTimeInterval(10)))
    #expect(!policy.replaysSameScene(last: nil, lastCapturedAt: start, current: same, now: start))
}

// MARK: Mecanismos de solicitud

@Test(arguments: [
    "describe el entorno", "describir", "¿qué hay delante?", "qué tengo enfrente",
    "qué hay a mi alrededor", "qué ves",
])
func voiceRecognizesTheNarrationRequest(phrase: String) {
    let interpretation = VoiceCommandInterpreter().interpret(phrase, hasActiveRoute: true)
    #expect(interpretation == .matched(.describeEnvironment))
}

@Test func helpMentionsTheNarrationCommand() {
    #expect(VoiceCommandInterpreter.helpPrompt.contains("Describe el entorno"))
}
