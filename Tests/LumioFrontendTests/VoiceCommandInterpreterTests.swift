import Testing
@testable import LumioFrontend

// HU Interactuar mediante voz: el sistema reconoce comandos soportados, pide aclaración
// cuando son ambiguos e informa cuando no los reconoce. Todo local, sin red.

private let interpreter = VoiceCommandInterpreter()

@Test func recognizesSupportedCommandsIgnoringAccentsCaseAndPunctuation() {
    let cases: [(String, VoiceCommand)] = [
        ("Ayuda", .help),
        ("¿Qué puedo decir?", .help),
        ("Repetir instrucción", .repeatInstruction),
        ("repite la indicación por favor", .repeatInstruction),
        ("¿Cómo voy?", .routeStatus),
        ("cuánto falta", .routeStatus),
        ("Llegué", .finishRoute(arrived: true)),
        ("Terminar la ruta", .finishRoute(arrived: false)),
        ("cancelar ruta", .finishRoute(arrived: false)),
        ("Detener navegación", .finishRoute(arrived: false)),
        ("nada", .stopListening),
        ("Nueva ruta", .navigate(destination: nil)),
    ]
    for (spoken, expected) in cases {
        #expect(interpreter.interpret(spoken, hasActiveRoute: true) == .matched(expected), "\(spoken)")
    }
}

@Test func extractsTheDestinationFromNavigationPhrases() {
    #expect(interpreter.interpret("Llévame a la Biblioteca Luis Ángel Arango", hasActiveRoute: false)
        == .matched(.navigate(destination: "la Biblioteca Luis Ángel Arango")))
    #expect(interpreter.interpret("quiero ir al parque", hasActiveRoute: false)
        == .matched(.navigate(destination: "parque")))
    #expect(interpreter.interpret("ruta hacia la estación", hasActiveRoute: true)
        == .matched(.navigate(destination: "la estación")))
}

@Test func navigationPhraseWithoutDestinationAsksForIt() {
    #expect(interpreter.interpret("llévame a", hasActiveRoute: false) == .matched(.navigate(destination: nil)))
}

@Test func longerPhraseWinsOverSingleAmbiguousWord() {
    // «ruta» sola es ambigua, pero «cancelar la ruta» no.
    #expect(interpreter.interpret("cancelar la ruta", hasActiveRoute: true) == .matched(.finishRoute(arrived: false)))
}

@Test func ambiguousWordAsksForClarification() {
    guard case .ambiguous(let options) = interpreter.interpret("ruta", hasActiveRoute: true) else {
        Issue.record("«ruta» debería ser ambiguo")
        return
    }
    #expect(options.map(\.kind) == [.routeStatus, .navigate, .finishRoute])
    let prompt = VoiceCommandInterpreter.clarificationPrompt(for: options)
    #expect(prompt.contains("terminar la ruta"))
    #expect(prompt.contains(" o "))
}

@Test func withoutActiveRouteAmbiguityDropsRouteOnlyActions() {
    // Sin ruta, «cancelar» solo puede ser cerrar la escucha.
    #expect(interpreter.interpret("cancelar", hasActiveRoute: false) == .matched(.stopListening))
    #expect(interpreter.interpret("cancelar", hasActiveRoute: true)
        == .ambiguous([.finishRoute(arrived: false), .stopListening]))
}

@Test func clarificationAnswerIsResolvedAmongCandidates() {
    let options: [VoiceCommand] = [.finishRoute(arrived: false), .stopListening]
    #expect(interpreter.interpret("la segunda", hasActiveRoute: true, among: options) == .matched(.stopListening))
    #expect(interpreter.interpret("terminar la ruta", hasActiveRoute: true, among: options)
        == .matched(.finishRoute(arrived: false)))
    // Algo que no es ninguna de las opciones no se acepta.
    #expect(interpreter.interpret("ayuda", hasActiveRoute: true, among: options) == .unrecognized)
}

@Test func unknownOrEmptyTextIsNotRecognized() {
    #expect(interpreter.interpret("pon música", hasActiveRoute: true) == .unrecognized)
    #expect(interpreter.interpret("   ", hasActiveRoute: true) == .unrecognized)
}

@Test func understandsYesAndNo() {
    #expect(interpreter.confirmation(in: "Sí") == .yes)
    #expect(interpreter.confirmation(in: "sí, claro") == .yes)
    #expect(interpreter.confirmation(in: "No") == .no)
    #expect(interpreter.confirmation(in: "mejor no") == .no)
    #expect(interpreter.confirmation(in: "sí… no") == .unclear)
    #expect(interpreter.confirmation(in: "el clima") == .unclear)
}

@Test func onlyFinishingARouteNeedsConfirmation() {
    #expect(VoiceCommand.finishRoute(arrived: false).requiresConfirmation)
    #expect(VoiceCommand.finishRoute(arrived: true).requiresConfirmation)
    #expect(!VoiceCommand.repeatInstruction.requiresConfirmation)
    #expect(!VoiceCommand.navigate(destination: "parque").requiresConfirmation)
}
