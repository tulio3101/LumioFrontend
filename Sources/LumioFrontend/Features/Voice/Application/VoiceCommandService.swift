import Foundation

/// HU Interactuar con la Aplicación Mediante Voz. Activa la escucha, reconoce el comando,
/// pide aclaración si es ambiguo, confirma las acciones que no se pueden deshacer y ejecuta
/// la acción con los casos de uso existentes. Todo lo que dice pasa por el AudioArbiter (P2),
/// así que una alerta crítica (P1) siempre lo interrumpe; si llega una P1 mientras escucha,
/// se corta la escucha para no competir con ella.
@MainActor
final class VoiceCommandService: ObservableObject {
    @Published private(set) var phase: VoicePhase = .idle
    /// Último texto entendido, para mostrarlo en pantalla.
    @Published private(set) var lastTranscript: String?

    weak var actions: (any VoiceActionPerforming)?

    private let listener: any SpeechListening
    private let permissions: any VoicePermissionGating
    private let audio: any VoiceAudioOutput
    private let interpreter: VoiceCommandInterpreter
    private var session: Task<Void, Never>?
    /// Distingue la sesión actual de una cancelada que todavía está terminando.
    private var sessionID = UUID()
    private var interruptedByAlert = false

    init(
        listener: any SpeechListening,
        permissions: any VoicePermissionGating,
        audio: any VoiceAudioOutput,
        interpreter: VoiceCommandInterpreter = VoiceCommandInterpreter()
    ) {
        self.listener = listener
        self.permissions = permissions
        self.audio = audio
        self.interpreter = interpreter
    }

    var isActive: Bool { phase != .idle }

    /// Botón «Comando de voz»: activa la escucha o, si ya está activa, la cierra.
    func toggle() {
        if isActive { cancel() } else { start() }
    }

    func start() {
        start(initial: nil)
    }

    /// Pantalla Principal Accesible: «Indicar destino por voz» y el Magic Tap preguntan
    /// directamente a dónde ir, con el mismo flujo que el comando «nueva ruta».
    func startDestinationDictation() {
        start(initial: .navigate(destination: nil))
    }

    private func start(initial: VoiceCommand?) {
        guard session == nil else { return }
        interruptedByAlert = false
        let id = UUID()
        sessionID = id
        session = Task { [weak self] in
            await self?.run(initial: initial)
            self?.finishSession(id)
        }
    }

    /// Cierra la escucha sin ejecutar nada.
    func cancel() {
        guard let session else { return }
        session.cancel()
        listener.stop()
        self.session = nil
        sessionID = UUID()
        phase = .idle
    }

    /// Espera a que termine la sesión en curso (pruebas).
    func waitUntilIdle() async {
        await session?.value
    }

    /// Lo llama el AudioArbiter con cada cambio de mensaje. Una alerta crítica que empieza
    /// a sonar mientras se escucha corta la escucha: la alerta tiene prioridad.
    func audioMessageChanged(_ message: AudioMessage) {
        guard message.priority == .immediateRisk, message.status == .playing,
              phase == .listening else { return }
        interruptedByAlert = true
        cancel()
        // P2: queda en cola y suena después de la alerta.
        audio.announce("Comando de voz interrumpido por una alerta. Vuelve a intentarlo.")
    }

    // MARK: - Conversación

    private func run(initial: VoiceCommand?) async {
        phase = .preparing
        guard await permissions.prepareVoiceInput() else {
            await speak(
                "Para usar comandos de voz, Lumio necesita el micrófono y el reconocimiento de voz. " +
                "Puedes concederlos en Preferencias, Permisos."
            )
            return
        }
        guard !Task.isCancelled else { return }
        if audio.isPlayingCriticalAlert {
            audio.announce("Hay una alerta en curso. Activa el comando de voz cuando termine.")
            return
        }
        if let initial {
            await handle(initial)
            return
        }
        await speak("Te escucho.")
        guard let transcript = await hear() else { return }
        await handle(interpreter.interpret(transcript, hasActiveRoute: actions?.hasActiveRoute ?? false))
    }

    private func handle(_ interpretation: VoiceInterpretation, clarifying: Bool = false) async {
        switch interpretation {
        case .unrecognized:
            await speak(VoiceCommandInterpreter.unrecognizedPrompt)
        case .ambiguous(let candidates):
            guard !clarifying else {
                await speak(VoiceCommandInterpreter.unrecognizedPrompt)
                return
            }
            await speak(VoiceCommandInterpreter.clarificationPrompt(for: candidates))
            guard let answer = await hear() else { return }
            let resolved = interpreter.interpret(
                answer, hasActiveRoute: actions?.hasActiveRoute ?? false, among: candidates
            )
            await handle(resolved, clarifying: true)
        case .matched(let command):
            await handle(command)
        }
    }

    private func handle(_ command: VoiceCommand) async {
        switch command {
        case .help:
            await speak(VoiceCommandInterpreter.helpPrompt)
        case .stopListening:
            await speak("De acuerdo.")
        case .navigate(nil):
            await speak("¿A dónde quieres ir?")
            guard let answer = await hear() else { return }
            let destination = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !destination.isEmpty else {
                await speak("No escuché un destino. Vuelve a intentarlo.")
                return
            }
            // La respuesta puede venir como «llévame a …»: se queda solo con el destino.
            if case .matched(.navigate(let parsed?)) = interpreter.interpret(destination, hasActiveRoute: false) {
                await execute(.navigate(destination: parsed))
            } else {
                await execute(.navigate(destination: destination))
            }
        case .finishRoute(let arrived):
            guard actions?.hasActiveRoute == true else {
                await speak("No hay una ruta activa.")
                return
            }
            await speak(arrived
                ? "¿Llegaste a tu destino? Di sí para terminar la ruta o no para continuar."
                : "¿Quieres terminar la ruta actual? Di sí para confirmar o no para continuar.")
            guard let answer = await hear() else { return }
            switch interpreter.confirmation(in: answer) {
            case .yes:
                await execute(command)
            case .no:
                await speak("De acuerdo. La ruta sigue activa.")
            case .unclear:
                await speak("No entendí la respuesta. La ruta sigue activa.")
            }
        default:
            await execute(command)
        }
    }

    private func execute(_ command: VoiceCommand) async {
        guard !Task.isCancelled else { return }
        phase = .processing
        if case .navigate(let destination?) = command {
            // Confirma qué se entendió antes de calcular; el resultado lo anuncia Crear Ruta.
            let verb = actions?.hasActiveRoute == true ? "Cambiando el destino a" : "Buscando una ruta a"
            await speak("\(verb) \(destination).")
        }
        guard let actions else {
            await speak("No puedo hacer eso desde esta pantalla.")
            return
        }
        if let reply = await actions.perform(command), !Task.isCancelled {
            await speak(reply)
        }
    }

    // MARK: - Escucha y voz

    /// Escucha una frase. nil si se canceló, falló o no se oyó nada (ya informado por audio).
    private func hear() async -> String? {
        guard !Task.isCancelled else { return nil }
        phase = .listening
        do {
            let text = try await listener.listen()
            guard !Task.isCancelled else { return nil }
            phase = .processing
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                await speak("No escuché nada. Vuelve a intentarlo cuando quieras.")
                return nil
            }
            lastTranscript = trimmed
            return trimmed
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled, !interruptedByAlert else { return nil }
            phase = .processing
            await speak("No pude escuchar. Vuelve a intentarlo.")
            return nil
        }
    }

    private func speak(_ text: String) async {
        guard !Task.isCancelled else { return }
        await audio.say(text)
    }

    private func finishSession(_ id: UUID) {
        guard id == sessionID else { return }
        session = nil
        phase = .idle
    }
}
