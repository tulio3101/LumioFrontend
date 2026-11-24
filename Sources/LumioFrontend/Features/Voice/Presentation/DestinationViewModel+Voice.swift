#if canImport(SwiftUI)
import Foundation

/// Los comandos de voz usan los mismos casos de uso que los botones de Trayecto. Los que ya
/// anuncian su resultado por audio (Crear, Modificar, Consultar y Finalizar Ruta) devuelven
/// nil para no repetirlo; los demás devuelven la confirmación a decir.
extension DestinationViewModel: VoiceActionPerforming {
    var hasActiveRoute: Bool { route != nil }

    func perform(_ command: VoiceCommand) async -> String? {
        switch command {
        case .repeatInstruction:
            guard route != nil else { return "No hay una ruta activa." }
            guard !isLoading else { return "Estoy calculando la ruta. Inténtalo en un momento." }
            return repeatCurrentInstruction() ? nil : "La ruta no tiene una instrucción para repetir."

        case .routeStatus:
            guard !isLoading, !isQueryingStatus else {
                return "Estoy calculando la ruta. Inténtalo en un momento."
            }
            // Consultar Ruta locuta el resultado, también sin ruta activa.
            _ = await queryRouteStatus()
            return nil

        case .navigate(let destination?):
            guard !isLoading else { return "Ya estoy calculando una ruta. Espera a que termine." }
            // Crear o Modificar Ruta anuncian por audio si la ruta quedó lista o por qué no.
            if route != nil {
                _ = await changeDestination(to: .query(destination))
            } else {
                _ = await createRoute(to: .query(destination))
            }
            return nil

        case .finishRoute(let arrived):
            guard route != nil else { return "No hay una ruta activa." }
            // Finalizar Ruta detiene las instrucciones y anuncia el cierre.
            guard !isLoading, !isFinishing else { return "Espera un momento e inténtalo de nuevo." }
            // Si el servicio no encontró la ruta, ya lo anunció; no se repite.
            _ = await finishRoute(outcome: arrived ? .completed : .cancelled)
            return nil

        case .help:
            return VoiceCommandInterpreter.helpPrompt

        case .navigate(nil), .stopListening:
            // Los resuelve VoiceCommandService antes de llegar aquí.
            return nil
        }
    }
}
#endif
