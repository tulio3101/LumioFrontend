import Foundation

/// Reconoce comandos en español a partir del texto transcrito, sin red ni backend.
/// Compara palabras normalizadas (sin tildes, mayúsculas ni puntuación) contra un catálogo
/// de frases; gana la coincidencia más larga. Si gana más de una acción, es ambiguo.
struct VoiceCommandInterpreter {
    private struct Phrase {
        let words: [String]
        let commands: [VoiceCommand]
    }

    private let phrases: [Phrase]
    private let destinationPrefixes: [[String]]

    init() {
        phrases = Self.catalog.map { Phrase(words: Self.words($0.0), commands: $0.1) }
        // Ordenados de mayor a menor para que «quiero ir a» gane sobre «ir a».
        destinationPrefixes = Self.destinationPrefixPhrases.map(Self.words).sorted { $0.count > $1.count }
    }

    /// - Parameters:
    ///   - hasActiveRoute: sin ruta, una ambigüedad no ofrece acciones que necesitan ruta.
    ///   - candidates: al responder una aclaración, solo se aceptan esas acciones (también
    ///     «la primera», «la segunda»…).
    func interpret(
        _ transcript: String,
        hasActiveRoute: Bool,
        among candidates: [VoiceCommand]? = nil
    ) -> VoiceInterpretation {
        let original = Self.tokens(transcript)
        let words = original.map(Self.fold)
        guard !words.isEmpty else { return .unrecognized }

        if let candidates, let index = Self.ordinal(in: words), candidates.indices.contains(index) {
            return .matched(candidates[index])
        }

        var scored: [(command: VoiceCommand, score: Int)] = []
        if let destination = destination(in: words, original: original) {
            scored.append((.navigate(destination: destination), 100 + destination.count))
        }
        for phrase in phrases where Self.contains(phrase.words, in: words) {
            for command in phrase.commands {
                scored.append((command, phrase.words.count))
            }
        }
        if let candidates {
            let allowed = Set(candidates.map(\.kind))
            scored = scored.filter { allowed.contains($0.command.kind) }
        }
        guard let best = scored.map(\.score).max() else { return .unrecognized }

        var winners: [VoiceCommand] = []
        for entry in scored where entry.score == best
            && !winners.contains(where: { $0.kind == entry.command.kind }) {
            winners.append(entry.command)
        }
        if winners.count > 1, !hasActiveRoute {
            let usable = winners.filter { !$0.needsActiveRoute }
            if !usable.isEmpty { winners = usable }
        }
        switch winners.count {
        case 1: return .matched(winners[0])
        case 0: return .unrecognized
        default: return .ambiguous(winners)
        }
    }

    /// Sí o no a una confirmación. Si aparecen ambas respuestas, no está claro.
    func confirmation(in transcript: String) -> VoiceConfirmation {
        let words = Self.words(transcript)
        let yes = Self.yesPhrases.contains { Self.contains(Self.words($0), in: words) }
        let no = Self.noPhrases.contains { Self.contains(Self.words($0), in: words) }
        switch (yes, no) {
        case (true, false): return .yes
        case (false, true): return .no
        default: return .unclear
        }
    }

    // MARK: - Textos hablados

    static let helpPrompt = """
        Puedes decir: llévame a, seguido del destino. Repetir instrucción. Cómo voy. \
        Llegué. Terminar ruta. O ayuda. Para cerrar sin hacer nada, di nada.
        """

    static let unrecognizedPrompt =
        "No reconocí el comando. Di ayuda para conocer los comandos disponibles."

    static func clarificationPrompt(for commands: [VoiceCommand]) -> String {
        let names = commands.map(\.clarificationName)
        guard names.count > 1 else { return unrecognizedPrompt }
        let list = names.dropLast().joined(separator: ", ") + " o " + names[names.count - 1]
        return "No estoy seguro de qué quieres hacer. ¿Quieres \(list)?"
    }

    // MARK: - Normalización y búsqueda

    /// Minúsculas, sin tildes ni puntuación, separado en palabras. «¿Llegué?» → ["llegue"].
    static func words(_ text: String) -> [String] {
        tokens(text).map(fold)
    }

    /// Palabras tal como se dijeron (con tildes y mayúsculas), sin puntuación.
    private static func tokens(_ text: String) -> [String] {
        let cleaned = String(text.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        })
        return cleaned.split(separator: " ").map(String.init)
    }

    private static func fold(_ word: String) -> String {
        word.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "es")
        ).lowercased()
    }

    /// El destino conserva las palabras originales: «la Biblioteca Luis Ángel Arango».
    private func destination(in words: [String], original: [String]) -> String? {
        for prefix in destinationPrefixes {
            guard let start = Self.index(of: prefix, in: words) else { continue }
            let range = (start + prefix.count)..<words.count
            let rest = range.filter { !Self.fillerWords.contains(words[$0]) }.map { original[$0] }
            // Sin destino («llévame a») se pregunta a dónde; se deja para el catálogo.
            guard !rest.isEmpty else { return nil }
            return rest.joined(separator: " ")
        }
        return nil
    }

    private static func contains(_ phrase: [String], in words: [String]) -> Bool {
        index(of: phrase, in: words) != nil
    }

    private static func index(of phrase: [String], in words: [String]) -> Int? {
        guard !phrase.isEmpty, phrase.count <= words.count else { return nil }
        for start in 0...(words.count - phrase.count)
        where Array(words[start..<(start + phrase.count)]) == phrase {
            return start
        }
        return nil
    }

    private static func ordinal(in words: [String]) -> Int? {
        let ordinals: [(Set<String>, Int)] = [
            (["primera", "primero", "uno", "1"], 0),
            (["segunda", "segundo", "dos", "2"], 1),
            (["tercera", "tercero", "tres", "3"], 2),
        ]
        guard words.count <= 3 else { return nil }
        for (names, index) in ordinals where words.contains(where: { names.contains($0) }) {
            return index
        }
        return nil
    }

    // MARK: - Catálogo

    /// Frases que introducen un destino: «llévame a la Biblioteca Nacional».
    private static let destinationPrefixPhrases = [
        "llevame a", "llevame al", "quiero ir a", "quiero ir al", "ir a", "ir al",
        "vamos a", "vamos al", "navegar a", "navega a", "ruta a", "ruta al", "ruta hacia",
        "como llego a", "como llego al", "nuevo destino", "cambiar destino a",
        "cambia el destino a", "cambiar el destino a", "destino",
    ]

    /// Palabras de relleno que no forman parte del destino («llévame a por favor la …»).
    private static let fillerWords: Set<String> = ["por", "favor", "porfa"]

    private static let catalog: [(String, [VoiceCommand])] = [
        // Ayuda
        ("ayuda", [.help]),
        ("que puedo decir", [.help]),
        ("que comandos hay", [.help]),
        ("comandos disponibles", [.help]),
        ("comandos", [.help]),
        // Repetir instrucción
        ("repetir", [.repeatInstruction]),
        ("repite", [.repeatInstruction]),
        ("repetir instruccion", [.repeatInstruction]),
        ("repite la instruccion", [.repeatInstruction]),
        ("repetir indicacion", [.repeatInstruction]),
        ("repite la indicacion", [.repeatInstruction]),
        ("que dijiste", [.repeatInstruction]),
        ("otra vez", [.repeatInstruction]),
        // Consultar ruta
        ("como voy", [.routeStatus]),
        ("cuanto falta", [.routeStatus]),
        ("donde estoy", [.routeStatus]),
        ("estado de la ruta", [.routeStatus]),
        ("consultar ruta", [.routeStatus]),
        ("consultar la ruta", [.routeStatus]),
        // Nuevo destino sin decir cuál
        ("nueva ruta", [.navigate(destination: nil)]),
        ("crear ruta", [.navigate(destination: nil)]),
        ("crear una ruta", [.navigate(destination: nil)]),
        ("nuevo destino", [.navigate(destination: nil)]),
        ("cambiar destino", [.navigate(destination: nil)]),
        ("cambiar el destino", [.navigate(destination: nil)]),
        ("llevame", [.navigate(destination: nil)]),
        ("quiero ir", [.navigate(destination: nil)]),
        // Llegué (finalizar como completada)
        ("llegue", [.finishRoute(arrived: true)]),
        ("ya llegue", [.finishRoute(arrived: true)]),
        ("llegue a mi destino", [.finishRoute(arrived: true)]),
        // Terminar sin llegar
        ("terminar ruta", [.finishRoute(arrived: false)]),
        ("terminar la ruta", [.finishRoute(arrived: false)]),
        ("termina la ruta", [.finishRoute(arrived: false)]),
        ("finalizar ruta", [.finishRoute(arrived: false)]),
        ("finalizar la ruta", [.finishRoute(arrived: false)]),
        ("cancelar ruta", [.finishRoute(arrived: false)]),
        ("cancelar la ruta", [.finishRoute(arrived: false)]),
        ("cancela la ruta", [.finishRoute(arrived: false)]),
        ("detener navegacion", [.finishRoute(arrived: false)]),
        ("detener la navegacion", [.finishRoute(arrived: false)]),
        ("terminar navegacion", [.finishRoute(arrived: false)]),
        ("terminar la navegacion", [.finishRoute(arrived: false)]),
        // Cerrar la escucha
        ("nada", [.stopListening]),
        ("olvidalo", [.stopListening]),
        ("dejar de escuchar", [.stopListening]),
        ("deja de escuchar", [.stopListening]),
        // Palabras sueltas que pueden ser varias cosas: se pide aclaración.
        ("ruta", [.routeStatus, .navigate(destination: nil), .finishRoute(arrived: false)]),
        ("cancelar", [.finishRoute(arrived: false), .stopListening]),
        ("cancela", [.finishRoute(arrived: false), .stopListening]),
        ("terminar", [.finishRoute(arrived: false), .stopListening]),
        ("detener", [.finishRoute(arrived: false), .stopListening]),
        ("parar", [.finishRoute(arrived: false), .stopListening]),
    ]

    private static let yesPhrases = [
        "si", "claro", "confirmo", "confirmar", "dale", "de acuerdo", "correcto", "hazlo", "ok", "okay",
    ]
    private static let noPhrases = [
        "no", "cancelar", "mejor no", "todavia no", "aun no", "negativo",
    ]
}
