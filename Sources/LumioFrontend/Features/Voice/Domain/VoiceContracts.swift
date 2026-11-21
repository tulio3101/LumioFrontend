import Foundation

/// Reconocimiento de voz de una sola frase. Devuelve "" si no se escuchó nada.
@MainActor
protocol SpeechListening: AnyObject {
    func listen() async throws -> String
    /// Corta la escucha en curso; `listen()` termina con CancellationError.
    func stop()
}

enum SpeechListeningError: Error, Equatable {
    /// El reconocedor de español no está disponible en este dispositivo o momento.
    case recognizerUnavailable
    /// No se pudo abrir el micrófono (por ejemplo, otra app lo está usando).
    case audioInputUnavailable
}

/// Permisos de micrófono y reconocimiento de voz, con el flujo accesible de SCRUM-315.
@MainActor
protocol VoicePermissionGating: AnyObject {
    /// Explica y solicita lo que falte. true si ambos permisos quedan concedidos.
    func prepareVoiceInput() async -> Bool
}

/// Lo que la voz necesita del audio: hablar SIEMPRE a través del AudioArbiter.
@MainActor
protocol VoiceAudioOutput: AnyObject {
    /// Habla y espera a que termine (para no escuchar la propia voz de Lumio).
    func say(_ text: String) async
    /// Habla sin esperar.
    func announce(_ text: String)
    /// Hay una alerta crítica (P1) sonando: no se abre el micrófono encima de ella.
    var isPlayingCriticalAlert: Bool { get }
}

/// Ejecuta las acciones con los casos de uso existentes (lo implementa DestinationViewModel).
@MainActor
protocol VoiceActionPerforming: AnyObject {
    var hasActiveRoute: Bool { get }
    /// Ejecuta el comando. Devuelve lo que hay que decir, o nil si el caso de uso ya lo
    /// anuncia por audio (Crear/Modificar/Consultar/Finalizar Ruta locutan su resultado).
    func perform(_ command: VoiceCommand) async -> String?
}
