import Foundation

/// Acciones que se pueden pedir por voz (HU Interactuar con la Aplicación Mediante Voz).
/// Cada una reutiliza un caso de uso existente; la voz no duplica lógica de navegación.
enum VoiceCommand: Equatable {
    /// Lee los comandos disponibles.
    case help
    /// Repetir la indicación actual (InstructionRepeating).
    case repeatInstruction
    /// Consultar la ruta actual, «¿cómo voy?» (RouteStatusQuerying, SCRUM-23).
    case routeStatus
    /// Crear Ruta o, con una ruta activa, Modificar Ruta. nil: hay que preguntar el destino.
    case navigate(destination: String?)
    /// Finalizar Ruta: `arrived` true = «llegué» (completada); false = terminar sin llegar.
    case finishRoute(arrived: Bool)
    /// Cerrar la escucha sin hacer nada.
    case stopListening
    /// SCRUM-39: Solicitar Narración del Entorno (EnvironmentNarrationService).
    case describeEnvironment

    /// Identidad sin datos asociados: sirve para comparar candidatos de una ambigüedad.
    var kind: Kind {
        switch self {
        case .help: return .help
        case .repeatInstruction: return .repeatInstruction
        case .routeStatus: return .routeStatus
        case .navigate: return .navigate
        case .finishRoute(let arrived): return arrived ? .arrived : .finishRoute
        case .stopListening: return .stopListening
        case .describeEnvironment: return .describeEnvironment
        }
    }

    enum Kind: Hashable {
        case help, repeatInstruction, routeStatus, navigate, arrived, finishRoute, stopListening
        case describeEnvironment
    }

    /// Acciones que no se pueden deshacer: se confirman por voz antes de ejecutarse para que
    /// una transcripción equivocada o ruido no termine la navegación.
    var requiresConfirmation: Bool {
        if case .finishRoute = self { return true }
        return false
    }

    /// Solo tienen sentido con una ruta activa; se descartan al resolver ambigüedades sin ruta.
    var needsActiveRoute: Bool {
        switch self {
        case .repeatInstruction, .finishRoute: return true
        default: return false
        }
    }

    /// Cómo se nombra en la pregunta de aclaración («¿Quieres … o …?»).
    var clarificationName: String {
        switch self {
        case .help: return "oír los comandos disponibles"
        case .repeatInstruction: return "repetir la instrucción"
        case .routeStatus: return "saber cómo vas en la ruta"
        case .navigate: return "ir a un nuevo destino"
        case .finishRoute(let arrived): return arrived ? "marcar que llegaste" : "terminar la ruta"
        case .stopListening: return "dejar de escuchar"
        case .describeEnvironment: return "describir lo que tienes delante"
        }
    }
}

/// Resultado de interpretar una transcripción.
enum VoiceInterpretation: Equatable {
    case matched(VoiceCommand)
    /// Varias acciones encajan por igual: se pregunta cuál (en el orden dado).
    case ambiguous([VoiceCommand])
    case unrecognized
}

/// Respuesta a una pregunta de sí o no.
enum VoiceConfirmation: Equatable {
    case yes, no, unclear
}

/// Estado visible de la entrada por voz.
enum VoicePhase: Equatable {
    case idle
    /// Preparando permisos y micrófono.
    case preparing
    case listening
    /// Ejecutando la acción o hablando la respuesta.
    case processing
}
