#if os(iOS)
import AVFoundation
import Foundation
import OSLog
import Speech

/// Reconocimiento local con SFSpeechRecognizer en español. Escucha una sola frase: termina
/// tras un silencio corto después de hablar, o al agotar el tiempo máximo. Si el dispositivo
/// lo permite, el reconocimiento ocurre en el iPhone (sin red).
@MainActor
final class DeviceSpeechListener: SpeechListening {
    /// Máximo para empezar a hablar y decir la frase.
    private let maxDuration: UInt64
    /// Silencio que da por terminada la frase una vez que el usuario habló.
    private let endOfSpeechSilence: UInt64

    private let recognizer: SFSpeechRecognizer?
    /// Se crea en cada escucha, después de activar la sesión de grabación: un motor creado antes
    /// conserva el formato de la sesión de reproducción del árbitro (`.playback`/`.voicePrompt`)
    /// y `installTap` lanza una excepción de Objective-C que cierra la app.
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var transcript = ""
    private var deadline: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.lumio.app", category: "DeviceSpeechListener")

    init(
        maxDuration: UInt64 = 8_000_000_000,
        endOfSpeechSilence: UInt64 = 1_500_000_000
    ) {
        self.maxDuration = maxDuration
        self.endOfSpeechSilence = endOfSpeechSilence
        recognizer = Self.spanishRecognizer()
    }

    func listen() async throws -> String {
        finish(with: .failure(CancellationError()))
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechListeningError.recognizerUnavailable
        }
        transcript = ""
        do {
            try startAudio(for: recognizer)
        } catch {
            logger.error("No se pudo abrir el micrófono: \(error)")
            tearDown()
            throw SpeechListeningError.audioInputUnavailable
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.restartDeadline(after: self.maxDuration)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        finish(with: .failure(CancellationError()))
    }

    // MARK: - Audio y reconocimiento

    private func startAudio(for recognizer: SFSpeechRecognizer) throws {
        let session = AVAudioSession.sharedInstance()
        // Mezcla con la reproducción: no corta el audio de Lumio que esté sonando.
        try session.setCategory(
            .playAndRecord, mode: .default,
            options: [.mixWithOthers, .duckOthers, .defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        guard session.isInputAvailable else { throw MicrophoneError.noInput }
        let engine = AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode
        // Formato real del micrófono. Si no es válido (0 Hz o 0 canales: la sesión aún no
        // cambió de ruta o el micrófono está ocupado), installTap lanzaría una NSException que
        // Swift no puede atrapar: se avisa «No pude escuchar» en lugar de cerrar la app.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneError.invalidFormat(sampleRate: format.sampleRate, channels: format.channelCount)
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                self?.handle(text: text, isFinal: isFinal, failed: failed)
            }
        }
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        guard continuation != nil else { return }
        if let text, !text.isEmpty, text != transcript {
            transcript = text
            // El usuario sigue hablando: se espera un silencio corto para cerrar la frase.
            restartDeadline(after: endOfSpeechSilence)
        }
        if isFinal {
            finish(with: .success(transcript))
        } else if failed {
            // Sin voz detectada el reconocedor también termina con error: se trata como silencio.
            finish(with: .success(transcript))
        }
    }

    private func restartDeadline(after nanoseconds: UInt64) {
        deadline?.cancel()
        deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.finish(with: .success(self.transcript))
        }
    }

    private func finish(with result: Result<String, Error>) {
        tearDown()
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func tearDown() {
        deadline?.cancel()
        deadline = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if let engine = audioEngine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
    }

    private enum MicrophoneError: Error {
        case noInput
        case invalidFormat(sampleRate: Double, channels: AVAudioChannelCount)
    }

    /// Español del dispositivo si es compatible (es-CO, es-MX…); si no, español de México.
    private static func spanishRecognizer() -> SFSpeechRecognizer? {
        let current = Locale.current
        if current.identifier.hasPrefix("es"), let recognizer = SFSpeechRecognizer(locale: current) {
            return recognizer
        }
        return SFSpeechRecognizer(locale: Locale(identifier: "es-MX"))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    }
}
#endif
