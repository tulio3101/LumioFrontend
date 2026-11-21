import Foundation

/// Fallos locales del detector. La ausencia de objetos NO es un fallo.
enum DetectionModelError: Error, Equatable {
    case modelNotFound
    case modelLoadingFailed
    case invalidOutput
    case inferenceFailed

    var canRetry: Bool {
        switch self {
        case .modelNotFound, .invalidOutput: return false
        case .modelLoadingFailed, .inferenceFailed: return true
        }
    }
}

enum SafetyFailure: Equatable {
    case model(DetectionModelError)
    case camera
}

enum SafetyStatus: Equatable {
    case stopped
    case starting
    case running
    case recovering(attempt: Int)
    case unavailable(SafetyFailure)

    var message: String {
        switch self {
        case .stopped: return "La detección de obstáculos está detenida."
        case .starting: return "Preparando la detección de obstáculos."
        case .running: return "La detección de obstáculos está activa."
        case .recovering(let attempt):
            return "La detección de obstáculos no está disponible. Intentando recuperarla, intento \(attempt)."
        case .unavailable(.model(.modelNotFound)):
            return "La detección no está disponible porque falta el modelo en esta versión de Lumio."
        case .unavailable(.model(.invalidOutput)):
            return "La detección no está disponible porque el modelo devolvió un resultado incompatible."
        case .unavailable(.model):
            return "La detección de obstáculos no está disponible. Puedes intentar recuperarla."
        case .unavailable(.camera):
            return "La detección no está disponible porque se interrumpió la captura de cámara."
        }
    }
}

struct ModelRecoveryPolicy {
    /// Máximo tres reconstrucciones automáticas por episodio. Sin descarga ni red.
    let delays: [UInt64]
    init(delays: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000]) {
        self.delays = delays
    }
}

/// Compatible con el deployment target iOS 16, sin depender de makeStream del SDK nuevo.
func makeSafetyStream<Element>(
    of type: Element.Type,
    bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded
) -> (stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
    var continuation: AsyncStream<Element>.Continuation!
    let stream = AsyncStream<Element>(bufferingPolicy: bufferingPolicy) { continuation = $0 }
    return (stream, continuation)
}
