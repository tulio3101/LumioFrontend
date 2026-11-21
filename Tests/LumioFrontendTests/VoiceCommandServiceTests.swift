import Foundation
import Testing
@testable import LumioFrontend

// HU Interactuar mediante voz: activar la entrada, ejecutar la acción, aclarar, confirmar
// y no interferir con alertas críticas. Sin micrófono real: escucha y audio falsos.

@MainActor
private final class ScriptedListener: SpeechListening {
    var replies: [Result<String, Error>]
    private(set) var listens = 0
    /// Se llama al empezar a escuchar (para simular una alerta mientras se escucha).
    var onListen: (() -> Void)?
    private var pending: CheckedContinuation<String, Error>?

    init(_ replies: [String]) { self.replies = replies.map { .success($0) } }

    func listen() async throws -> String {
        listens += 1
        if let onListen {
            self.onListen = nil
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                onListen()
            }
        }
        guard !replies.isEmpty else { return "" }
        return try replies.removeFirst().get()
    }

    func stop() {
        pending?.resume(throwing: CancellationError())
        pending = nil
    }
}

@MainActor
private final class FakePermissions: VoicePermissionGating {
    var granted = true
    private(set) var requests = 0
    func prepareVoiceInput() async -> Bool {
        requests += 1
        return granted
    }
}

@MainActor
private final class RecordingAudio: VoiceAudioOutput {
    private(set) var spoken: [String] = []
    var isPlayingCriticalAlert = false
    func say(_ text: String) async { spoken.append(text) }
    func announce(_ text: String) { spoken.append(text) }
}

@MainActor
private final class FakeActions: VoiceActionPerforming {
    var hasActiveRoute: Bool
    var reply: String?
    private(set) var performed: [VoiceCommand] = []
    init(hasActiveRoute: Bool = true, reply: String? = nil) {
        self.hasActiveRoute = hasActiveRoute
        self.reply = reply
    }
    func perform(_ command: VoiceCommand) async -> String? {
        performed.append(command)
        return reply
    }
}

@MainActor
private func run(
    _ replies: [String],
    actions: FakeActions = FakeActions(),
    permissions: FakePermissions = FakePermissions(),
    audio: RecordingAudio = RecordingAudio()
) async -> (VoiceCommandService, RecordingAudio, FakeActions) {
    let service = VoiceCommandService(
        listener: ScriptedListener(replies), permissions: permissions, audio: audio
    )
    service.actions = actions
    service.start()
    await service.waitUntilIdle()
    return (service, audio, actions)
}

@Test @MainActor func activatingVoiceListensAndRunsTheCommand() async {
    let (service, audio, actions) = await run(["repetir instrucción"])
    #expect(audio.spoken.first == "Te escucho.")
    #expect(actions.performed == [.repeatInstruction])
    #expect(service.phase == .idle)
    #expect(service.lastTranscript == "repetir instrucción")
}

@Test @MainActor func navigationConfirmsWhatItUnderstoodBeforeCalculating() async {
    let (_, audio, actions) = await run(["llévame al parque"], actions: FakeActions(hasActiveRoute: false))
    #expect(audio.spoken.contains("Buscando una ruta a parque."))
    #expect(actions.performed == [.navigate(destination: "parque")])
}

@Test @MainActor func navigationWithoutDestinationAsksWhereToGo() async {
    let (_, audio, actions) = await run(["nueva ruta", "llévame a la estación"], actions: FakeActions(hasActiveRoute: false))
    #expect(audio.spoken.contains("¿A dónde quieres ir?"))
    #expect(actions.performed == [.navigate(destination: "la estación")])
}

@Test @MainActor func actionReplyIsSpokenWhenTheUseCaseDoesNotAnnounceIt() async {
    let (_, audio, _) = await run(["repetir"], actions: FakeActions(reply: "No hay una ruta activa."))
    #expect(audio.spoken.last == "No hay una ruta activa.")
}

@Test @MainActor func unrecognizedCommandIsReportedAndNothingRuns() async {
    let (_, audio, actions) = await run(["pon música"])
    #expect(audio.spoken.last == VoiceCommandInterpreter.unrecognizedPrompt)
    #expect(actions.performed.isEmpty)
}

@Test @MainActor func ambiguousCommandAsksAndRunsTheChosenOption() async {
    let (_, audio, actions) = await run(["ruta", "cómo voy"])
    #expect(audio.spoken.contains { $0.hasPrefix("No estoy seguro de qué quieres hacer") })
    #expect(actions.performed == [.routeStatus])
}

@Test @MainActor func finishingTheRouteRequiresAYes() async {
    let (_, audio, actions) = await run(["terminar la ruta", "sí"])
    #expect(audio.spoken.contains { $0.hasPrefix("¿Quieres terminar la ruta actual?") })
    #expect(actions.performed == [.finishRoute(arrived: false)])
}

@Test @MainActor func sayingNoKeepsTheRoute() async {
    let (_, audio, actions) = await run(["llegué", "no"])
    #expect(actions.performed.isEmpty)
    #expect(audio.spoken.last == "De acuerdo. La ruta sigue activa.")
}

@Test @MainActor func unclearConfirmationKeepsTheRoute() async {
    let (_, audio, actions) = await run(["cancelar ruta", "el clima"])
    #expect(actions.performed.isEmpty)
    #expect(audio.spoken.last == "No entendí la respuesta. La ruta sigue activa.")
}

@Test @MainActor func finishingWithoutRouteIsReportedWithoutAsking() async {
    let (_, audio, actions) = await run(["terminar la ruta"], actions: FakeActions(hasActiveRoute: false))
    #expect(actions.performed.isEmpty)
    #expect(audio.spoken.last == "No hay una ruta activa.")
}

@Test @MainActor func silenceIsReported() async {
    let (_, audio, actions) = await run([""])
    #expect(actions.performed.isEmpty)
    #expect(audio.spoken.last == "No escuché nada. Vuelve a intentarlo cuando quieras.")
}

@Test @MainActor func missingPermissionsAreExplainedAndMicrophoneStaysClosed() async {
    let permissions = FakePermissions()
    permissions.granted = false
    let listener = ScriptedListener(["ayuda"])
    let audio = RecordingAudio()
    let service = VoiceCommandService(listener: listener, permissions: permissions, audio: audio)
    service.start()
    await service.waitUntilIdle()
    #expect(listener.listens == 0)
    #expect(audio.spoken.last?.contains("micrófono y el reconocimiento de voz") == true)
}

@Test @MainActor func doesNotOpenTheMicrophoneOverACriticalAlert() async {
    let listener = ScriptedListener(["ayuda"])
    let audio = RecordingAudio()
    audio.isPlayingCriticalAlert = true
    let service = VoiceCommandService(listener: listener, permissions: FakePermissions(), audio: audio)
    service.start()
    await service.waitUntilIdle()
    #expect(listener.listens == 0)
    #expect(audio.spoken == ["Hay una alerta en curso. Activa el comando de voz cuando termine."])
}

@Test @MainActor func criticalAlertWhileListeningStopsListeningAndRunsNothing() async {
    let listener = ScriptedListener([])
    let audio = RecordingAudio()
    let actions = FakeActions()
    let service = VoiceCommandService(listener: listener, permissions: FakePermissions(), audio: audio)
    service.actions = actions
    listener.onListen = {
        var alert = AudioMessage(text: "Persona a un metro", priority: .immediateRisk, contextID: "safety")
        alert.status = .playing
        service.audioMessageChanged(alert)
    }
    service.start()
    await service.waitUntilIdle()
    #expect(service.phase == .idle)
    #expect(actions.performed.isEmpty)
    #expect(audio.spoken.last == "Comando de voz interrumpido por una alerta. Vuelve a intentarlo.")
}

@Test @MainActor func nonCriticalAudioDoesNotInterruptListening() async {
    let listener = ScriptedListener(["ayuda"])
    let audio = RecordingAudio()
    let service = VoiceCommandService(listener: listener, permissions: FakePermissions(), audio: audio)
    var instruction = AudioMessage(text: "Gira a la derecha", priority: .routeInformation)
    instruction.status = .playing
    service.audioMessageChanged(instruction)
    service.start()
    await service.waitUntilIdle()
    #expect(audio.spoken.last == VoiceCommandInterpreter.helpPrompt)
}

@Test @MainActor func tappingAgainClosesTheSession() async {
    let listener = ScriptedListener([])
    let audio = RecordingAudio()
    let service = VoiceCommandService(listener: listener, permissions: FakePermissions(), audio: audio)
    listener.onListen = {
        #expect(service.phase == .listening)
        service.toggle()
    }
    service.start()
    await service.waitUntilIdle()
    #expect(service.phase == .idle)
    // Cerrar no ejecuta ni dice nada más.
    #expect(audio.spoken == ["Te escucho."])
}
