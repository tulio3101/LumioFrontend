import Foundation

/// Lugar o dirección sugerida mientras se escribe el destino.
struct DestinationSuggestion: Equatable, Identifiable {
    let id: String
    let title: String
    /// Dirección o zona; puede venir vacía.
    let subtitle: String

    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        id = "\(title)\n\(subtitle)"
    }

    /// Texto completo: se lee en VoiceOver y sirve de consulta si no se puede resolver el lugar.
    var fullText: String {
        subtitle.isEmpty ? title : "\(title), \(subtitle)"
    }
}

/// Autocompletado del destino. Elegir una sugerencia confirma el destino.
@MainActor
protocol DestinationSuggesting {
    /// Sugerencias para el texto escrito. Puede lanzar error si el proveedor no responde.
    func suggestions(for query: String) async throws -> [DestinationSuggestion]
    /// Ubicación de una sugerencia devuelta antes por `suggestions(for:)`.
    func place(for suggestion: DestinationSuggestion) async throws -> RoutePlace
}

/// Cuándo pedir sugerencias y cuántas mostrar.
enum DestinationSuggestionPolicy {
    /// Con menos letras los resultados son ruido.
    static let minimumQueryLength = 3
    /// Pocas opciones: se recorren rápido con VoiceOver (ley de Hick).
    static let maximumResults = 5
    /// Espera tras la última tecla antes de consultar.
    static let debounceNanoseconds: UInt64 = 300_000_000

    /// Texto a consultar, o nil si todavía no vale la pena buscar.
    static func query(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= minimumQueryLength ? trimmed : nil
    }

    /// Quita duplicados y vacíos y limita la lista.
    static func normalized(_ suggestions: [DestinationSuggestion]) -> [DestinationSuggestion] {
        var seen = Set<String>()
        var result: [DestinationSuggestion] = []
        for suggestion in suggestions {
            let cleaned = DestinationSuggestion(
                title: suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines),
                subtitle: suggestion.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard !cleaned.title.isEmpty, seen.insert(cleaned.id).inserted else { continue }
            result.append(cleaned)
            if result.count == maximumResults { break }
        }
        return result
    }

    /// Anuncio para VoiceOver cuando cambia la lista.
    static func announcement(count: Int) -> String? {
        switch count {
        case 0: return nil
        case 1: return "1 sugerencia."
        default: return "\(count) sugerencias."
        }
    }
}

/// Plataformas sin autocompletado: el destino se escribe completo.
struct NoDestinationSuggestions: DestinationSuggesting {
    func suggestions(for query: String) async throws -> [DestinationSuggestion] { [] }

    func place(for suggestion: DestinationSuggestion) async throws -> RoutePlace {
        throw RouteCreationError.destinationNotFound
    }
}
