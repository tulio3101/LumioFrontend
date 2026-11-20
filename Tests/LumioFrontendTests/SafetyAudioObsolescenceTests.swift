import Testing
@testable import LumioFrontend

// SCRUM-33: la obsolescencia por captura aplica a las alertas de obstáculo aunque sean
// immediateRisk; los avisos de sistema (sin captureSequence) nunca se descartan por esto.

private func obstacleAlert(seq: UInt64, class cls: String = "person") -> AudioMessage {
    AudioMessage(
        text: cls,
        priority: .immediateRisk,
        contextID: "safety",
        deduplicationKey: "obstacle-\(cls)",
        captureSequence: seq
    )
}

@Test @MainActor func staleImmediateRiskObstacleAlertIsDiscarded() {
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player)

    arbiter.receive(obstacleAlert(seq: 5))   // suena; última captura de "safety" = 5
    #expect(arbiter.currentMessage?.captureSequence == 5)

    arbiter.receive(obstacleAlert(seq: 3))   // captura más vieja → descartada, aunque immediateRisk
    #expect(arbiter.pendingMessages.isEmpty)

    arbiter.receive(obstacleAlert(seq: 7))   // captura más nueva → aceptada
    #expect(arbiter.pendingMessages.map(\.captureSequence) == [7])
}

@Test @MainActor func systemSafetyAlertsAreNotDiscardedByObsolescence() {
    let player = FakeAudioPlayer()
    let arbiter = AudioArbiterService(player: player)

    arbiter.receive(obstacleAlert(seq: 10))         // última captura de "safety" = 10
    arbiter.receive(SafetyAudio.modelUnavailable()) // sin captureSequence → nunca se descarta
    arbiter.receive(SafetyAudio.cameraUnavailable())

    let keys = arbiter.pendingMessages.compactMap(\.deduplicationKey)
    #expect(keys.contains("safety-unavailable"))
    #expect(keys.contains("safety-no-camera"))
}
