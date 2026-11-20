import Testing
@testable import LumioFrontend

// SCRUM-37 / SCRUM-315: mensajes de audio de la asistencia de obstáculos.

@Test func modelUnavailableIsImmediateRiskAndStaysInSafetyContext() {
    let message = SafetyAudio.modelUnavailable()
    #expect(message.priority == .immediateRisk)
    #expect(message.contextID == "safety")
    #expect(message.deduplicationKey == "safety-unavailable")
    // El aviso deja claro que la navegación sigue funcionando.
    #expect(message.text.lowercased().contains("navegación sigue"))
}

@Test func cameraUnavailableIsEnvironmentInfoAndStaysInSafetyContext() {
    let message = SafetyAudio.cameraUnavailable()
    #expect(message.priority == .environmentInformation)
    #expect(message.contextID == "safety")
    #expect(message.deduplicationKey == "safety-no-camera")
}
