import Foundation

/// SCRUM-313: un lugar encontrado para el destino dictado, con lo necesario para leerlo en
/// voz alta y distinguirlo de otros con el mismo nombre.
struct SpokenPlace: Equatable {
    let place: RoutePlace
    /// Calle o barrio y ciudad, si el proveedor los da.
    let detail: String?

    var spoken: String {
        guard let detail, !detail.isEmpty else { return place.name }
        return "\(place.name), \(detail)"
    }
}

/// Resultado de buscar el destino dictado.
enum DestinationLookup: Equatable {
    /// Hasta `DestinationDictationPolicy.maxOptions` lugares, del más probable al menos.
    case found([SpokenPlace])
    /// El proveedor respondió, pero no hay ningún lugar con ese nombre cerca.
    case notFound
    /// No se pudo buscar (sin red o sin ubicación). Se sigue con el texto dictado y Crear
    /// Ruta informa el fallo por audio.
    case unavailable
}

/// Busca el destino dictado cerca del usuario (lo implementa MapKitDestinationLookup).
@MainActor
protocol DestinationLookingUp: AnyObject {
    func lookUp(_ query: String) async -> DestinationLookup
}

/// Respuesta a «¿cuál quieres?».
enum DestinationChoice: Equatable {
    case option(Int)
    /// «Ninguno», «otro»: el usuario quiere decir otro destino.
    case none
    case unclear
}

enum DestinationDictationPolicy {
    /// Más de tres opciones leídas en voz alta ya no se recuerdan.
    static let maxOptions = 3
    /// Cuántas veces se puede pedir el destino de nuevo antes de rendirse.
    static let attempts = 2

    /// Un lugar por nombre y dirección, en el orden del proveedor, hasta `maxOptions`.
    static func options(_ places: [SpokenPlace]) -> [SpokenPlace] {
        var seen = Set<String>()
        var result: [SpokenPlace] = []
        for place in places where place.place.coordinate.isValid {
            let key = VoiceCommandInterpreter.words(place.spoken).joined(separator: " ")
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(place)
            if result.count == maxOptions { break }
        }
        return result
    }

    static func confirmationPrompt(for place: SpokenPlace) -> String {
        "Entendí \(place.spoken). ¿Quieres ir ahí? Di sí o no."
    }

    static func unverifiedPrompt(for query: String) -> String {
        "Entendí \(query). Ahora no puedo comprobar el lugar. ¿Busco una ruta a \(query)? Di sí o no."
    }

    static func optionsPrompt(for places: [SpokenPlace], query: String) -> String {
        let numbers = ["Uno", "Dos", "Tres"]
        let items = places.enumerated().map { index, place in
            "\(numbers[min(index, numbers.count - 1)]): \(place.spoken)."
        }
        return "Encontré \(places.count) lugares para \(query). " + items.joined(separator: " ")
            + " ¿Cuál quieres? Di el número o di ninguno."
    }

    static func notFound(_ query: String) -> String {
        "No encontré \(query)."
    }

    static let askAgain = "Dime el destino de nuevo."
    static let giveUp = "No busqué ninguna ruta. Puedes intentarlo de nuevo con otro nombre o una dirección."
}

extension VoiceCommandInterpreter {
    /// «La segunda», «dos», el nombre de una de las opciones o «ninguno».
    func destinationChoice(in transcript: String, options: [String]) -> DestinationChoice {
        let words = Self.words(transcript)
        guard !words.isEmpty else { return .unclear }
        let rejections: Set<String> = ["ninguno", "ninguna", "otro", "otra", "ningun"]
        if words.contains(where: { rejections.contains($0) }) || words == ["no"] {
            return .none
        }
        if let index = Self.choiceOrdinal(in: words), options.indices.contains(index) {
            return .option(index)
        }
        // Por nombre: la única opción cuyas palabras dijo el usuario.
        let ignored: Set<String> = ["el", "la", "los", "las", "de", "del", "a", "al", "en", "y"]
        let said = Set(words).subtracting(ignored)
        let matches = options.indices.filter { index in
            let name = Set(Self.words(options[index])).subtracting(ignored)
            return !name.isEmpty && !said.isEmpty && (name.isSubset(of: said) || said.isSubset(of: name))
        }
        return matches.count == 1 ? .option(matches[0]) : .unclear
    }

    private static func choiceOrdinal(in words: [String]) -> Int? {
        let ordinals: [(Set<String>, Int)] = [
            (["primera", "primero", "uno", "1"], 0),
            (["segunda", "segundo", "dos", "2"], 1),
            (["tercera", "tercero", "tres", "3"], 2),
        ]
        guard words.count <= 4 else { return nil }
        let found = ordinals.filter { names, _ in words.contains(where: { names.contains($0) }) }
        return found.count == 1 ? found[0].1 : nil
    }
}
