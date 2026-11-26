import Foundation
import Testing
@testable import LumioFrontend

// SCRUM-313: Indicar Destino por Voz. Escucha, búsqueda y audio falsos.

@MainActor
private final class Listener: SpeechListening {
    var replies: [String]
    init(_ replies: [String]) { self.replies = replies }
    func listen() async throws -> String { replies.isEmpty ? "" : replies.removeFirst() }
    func stop() {}
}

@MainActor
private final class Permissions: VoicePermissionGating {
    func prepareVoiceInput() async -> Bool { true }
}

@MainActor
private final class Audio: VoiceAudioOutput {
    private(set) var spoken: [String] = []
    var isPlayingCriticalAlert = false
    func say(_ text: String) async { spoken.append(text) }
    func announce(_ text: String) { spoken.append(text) }
}

@MainActor
private final class Actions: VoiceActionPerforming {
    var hasActiveRoute: Bool
    private(set) var destinations: [DestinationRequest] = []
    private(set) var performed: [VoiceCommand] = []
    init(hasActiveRoute: Bool = false) { self.hasActiveRoute = hasActiveRoute }
    func perform(_ command: VoiceCommand) async -> String? {
        performed.append(command)
        return nil
    }
    func navigate(to destination: DestinationRequest) async -> String? {
        destinations.append(destination)
        return nil
    }
}

@MainActor
private final class Lookup: DestinationLookingUp {
    var results: [String: DestinationLookup]
    private(set) var queries: [String] = []
    init(_ results: [String: DestinationLookup]) { self.results = results }
    func lookUp(_ query: String) async -> DestinationLookup {
        queries.append(query)
        return results[query] ?? .notFound
    }
}

private func place(_ name: String, _ detail: String? = nil, lat: Double = 4.6) -> SpokenPlace {
    SpokenPlace(place: RoutePlace(name: name, coordinate: GeoCoordinate(latitude: lat, longitude: -74.07)), detail: detail)
}

private let library = place("Biblioteca Luis Ángel Arango", "Calle 11 4-14, Bogotá")
private let parkNorth = place("Parque de la 93", "Calle 93A, Bogotá", lat: 4.676)
private let parkSouth = place("Parque Tunal", "Carrera 24, Bogotá", lat: 4.57)

@MainActor
private func dictate(
    _ replies: [String],
    lookup: Lookup,
    actions: Actions? = nil,
    fromCommand: Bool = false
) async -> (Audio, Actions) {
    // Los valores por defecto se evalúan fuera del MainActor: se crean aquí dentro.
    let actions = actions ?? Actions()
    let audio = Audio()
    let service = VoiceCommandService(
        listener: Listener(replies), permissions: Permissions(), audio: audio, lookup: lookup
    )
    service.actions = actions
    if fromCommand { service.start() } else { service.startDestinationDictation() }
    await service.waitUntilIdle()
    #expect(service.phase == .idle)
    return (audio, actions)
}

// MARK: Confirmación

@Test @MainActor func readsBackThePlaceAndWaitsForYesBeforeRouting() async {
    let lookup = Lookup(["la biblioteca luis angel arango": .found([library])])
    let (audio, actions) = await dictate(["la biblioteca luis angel arango", "sí"], lookup: lookup)
    #expect(audio.spoken.first == "¿A dónde quieres ir?")
    #expect(audio.spoken.contains(DestinationDictationPolicy.confirmationPrompt(for: library)))
    #expect(audio.spoken.contains("Buscando una ruta a Biblioteca Luis Ángel Arango."))
    // El destino ya viene geocodificado para Crear Ruta.
    #expect(actions.destinations == [.place(library.place)])
}

@Test @MainActor func sayingNoAsksForTheDestinationAgain() async {
    let lookup = Lookup(["biblioteca": .found([library]), "parque de la 93": .found([parkNorth])])
    let (audio, actions) = await dictate(["biblioteca", "no", "parque de la 93", "sí"], lookup: lookup)
    #expect(audio.spoken.contains(DestinationDictationPolicy.askAgain))
    #expect(lookup.queries == ["biblioteca", "parque de la 93"])
    #expect(actions.destinations == [.place(parkNorth.place)])
}

@Test @MainActor func unclearAnswersGiveUpAfterTheSecondTry() async {
    let lookup = Lookup(["biblioteca": .found([library])])
    let (audio, actions) = await dictate(["biblioteca", "tal vez", "biblioteca", "quizás"], lookup: lookup)
    #expect(audio.spoken.filter { $0 == "No entendí la respuesta." }.count == 2)
    #expect(audio.spoken.last == DestinationDictationPolicy.giveUp)
    #expect(actions.destinations.isEmpty)
}

@Test @MainActor func silenceAfterTheQuestionRunsNothing() async {
    let lookup = Lookup(["biblioteca": .found([library])])
    let (audio, actions) = await dictate(["biblioteca", ""], lookup: lookup)
    #expect(audio.spoken.last == "No escuché nada. Vuelve a intentarlo cuando quieras.")
    #expect(actions.destinations.isEmpty)
}

@Test @MainActor func withAnActiveRouteTheDestinationChanges() async {
    let lookup = Lookup(["biblioteca": .found([library])])
    let (audio, actions) = await dictate(["biblioteca", "sí"], lookup: lookup, actions: Actions(hasActiveRoute: true))
    #expect(audio.spoken.contains("Cambiando el destino a Biblioteca Luis Ángel Arango."))
    #expect(actions.destinations == [.place(library.place)])
}

@Test @MainActor func takeMeToCommandAlsoConfirms() async {
    let lookup = Lookup(["la biblioteca": .found([library])])
    let (audio, actions) = await dictate(["llévame a la biblioteca", "sí"], lookup: lookup, fromCommand: true)
    #expect(audio.spoken.first == "Te escucho.")
    #expect(audio.spoken.contains(DestinationDictationPolicy.confirmationPrompt(for: library)))
    #expect(actions.destinations == [.place(library.place)])
    #expect(actions.performed.isEmpty)
}

// MARK: Ambigüedad y no encontrado

@Test @MainActor func severalPlacesAreReadAndTheChosenOneIsUsed() async {
    let lookup = Lookup(["parque": .found([parkNorth, parkSouth])])
    let (audio, actions) = await dictate(["parque", "la segunda"], lookup: lookup)
    #expect(audio.spoken.contains(DestinationDictationPolicy.optionsPrompt(for: [parkNorth, parkSouth], query: "parque")))
    #expect(actions.destinations == [.place(parkSouth.place)])
}

@Test @MainActor func aPlaceCanBeChosenByName() async {
    let lookup = Lookup(["parque": .found([parkNorth, parkSouth])])
    let (_, actions) = await dictate(["parque", "el tunal"], lookup: lookup)
    #expect(actions.destinations == [.place(parkSouth.place)])
}

@Test @MainActor func noneOfTheOptionsAsksAgain() async {
    let lookup = Lookup(["parque": .found([parkNorth, parkSouth]), "biblioteca": .found([library])])
    let (_, actions) = await dictate(["parque", "ninguno", "biblioteca", "sí"], lookup: lookup)
    #expect(actions.destinations == [.place(library.place)])
}

@Test @MainActor func unknownPlaceIsReportedAndAskedAgain() async {
    let lookup = Lookup(["biblioteca": .found([library])])
    let (audio, actions) = await dictate(["bibliotca xyz", "biblioteca", "sí"], lookup: lookup)
    #expect(audio.spoken.contains("No encontré bibliotca xyz."))
    #expect(actions.destinations == [.place(library.place)])
}

@Test @MainActor func twoUnknownPlacesGiveUpWithoutRouting() async {
    let (audio, actions) = await dictate(["xyz", "abc"], lookup: Lookup([:]))
    #expect(audio.spoken.contains("No encontré xyz."))
    #expect(audio.spoken.contains("No encontré abc."))
    #expect(audio.spoken.last == DestinationDictationPolicy.giveUp)
    #expect(actions.destinations.isEmpty)
}

@Test @MainActor func withoutLookupTheTextIsConfirmedAndSentAsTyped() async {
    let lookup = Lookup(["biblioteca": .unavailable])
    let (audio, actions) = await dictate(["biblioteca", "sí"], lookup: lookup)
    #expect(audio.spoken.contains(DestinationDictationPolicy.unverifiedPrompt(for: "biblioteca")))
    #expect(actions.destinations == [.query("biblioteca")])
}

// MARK: Reglas

@Test func choiceUnderstandsOrdinalsNamesAndNone() {
    let interpreter = VoiceCommandInterpreter()
    let options = ["Parque de la 93", "Parque Tunal", "Parque Simón Bolívar"]
    #expect(interpreter.destinationChoice(in: "la primera", options: options) == .option(0))
    #expect(interpreter.destinationChoice(in: "dos", options: options) == .option(1))
    #expect(interpreter.destinationChoice(in: "el tercero", options: options) == .option(2))
    #expect(interpreter.destinationChoice(in: "Simón Bolívar", options: options) == .option(2))
    #expect(interpreter.destinationChoice(in: "ninguno", options: options) == .none)
    #expect(interpreter.destinationChoice(in: "otro", options: options) == .none)
    // «Parque» está en las tres: no alcanza para elegir.
    #expect(interpreter.destinationChoice(in: "parque", options: options) == .unclear)
    #expect(interpreter.destinationChoice(in: "la cuarta", options: options) == .unclear)
    #expect(interpreter.destinationChoice(in: "", options: options) == .unclear)
}

@Test func optionsAreDeduplicatedAndLimitedToThree() {
    let duplicate = place("Parque de la 93", "Calle 93A, Bogotá", lat: 4.677)
    let invalid = SpokenPlace(place: RoutePlace(name: "Nada", coordinate: GeoCoordinate(latitude: 200, longitude: 0)), detail: nil)
    let extra = place("Parque Nacional", "Carrera 7")
    let options = DestinationDictationPolicy.options([parkNorth, duplicate, invalid, parkSouth, library, extra])
    #expect(options == [parkNorth, parkSouth, library])
}

@Test func spokenPlaceIncludesTheAddressWhenKnown() {
    #expect(library.spoken == "Biblioteca Luis Ángel Arango, Calle 11 4-14, Bogotá")
    #expect(place("Casa").spoken == "Casa")
}
