import Foundation
import Testing
@testable import LumioFrontend

@Test(arguments: zip(
    ["", "  ", "Fa", " Fa ", "Far", "  Farmacia  "],
    [nil, nil, nil, nil, "Far", "Farmacia"] as [String?]
))
func suggestionsNeedAtLeastThreeLetters(text: String, expected: String?) {
    #expect(DestinationSuggestionPolicy.query(for: text) == expected)
}

@Test func suggestionsAreTrimmedDeduplicatedAndLimited() {
    let raw = [
        DestinationSuggestion(title: " Farmacia Central ", subtitle: "Calle 10 # 5-20 "),
        DestinationSuggestion(title: "Farmacia Central", subtitle: "Calle 10 # 5-20"),
        DestinationSuggestion(title: "   ", subtitle: "Sin nombre"),
    ] + (1...10).map { DestinationSuggestion(title: "Farmacia \($0)", subtitle: "") }

    let suggestions = DestinationSuggestionPolicy.normalized(raw)

    #expect(suggestions.count == DestinationSuggestionPolicy.maximumResults)
    #expect(suggestions.first == DestinationSuggestion(title: "Farmacia Central", subtitle: "Calle 10 # 5-20"))
    #expect(suggestions.filter { $0.title == "Farmacia Central" }.count == 1)
    #expect(!suggestions.contains { $0.title.isEmpty })
}

@Test func suggestionReadsTitleAndAddressTogether() {
    #expect(
        DestinationSuggestion(title: "Farmacia Central", subtitle: "Calle 10 # 5-20").fullText
            == "Farmacia Central, Calle 10 # 5-20"
    )
    #expect(DestinationSuggestion(title: "Parque Nacional", subtitle: "").fullText == "Parque Nacional")
}

@Test func suggestionCountIsAnnouncedInSpanish() {
    #expect(DestinationSuggestionPolicy.announcement(count: 0) == nil)
    #expect(DestinationSuggestionPolicy.announcement(count: 1) == "1 sugerencia.")
    #expect(DestinationSuggestionPolicy.announcement(count: 4) == "4 sugerencias.")
}

@MainActor
@Test func platformsWithoutAutocompleteOfferNoSuggestions() async throws {
    let suggester = NoDestinationSuggestions()
    let suggestion = DestinationSuggestion(title: "Farmacia Central", subtitle: "")

    #expect(try await suggester.suggestions(for: "Farmacia").isEmpty)
    await #expect(throws: RouteCreationError.destinationNotFound) {
        try await suggester.place(for: suggestion)
    }
}
