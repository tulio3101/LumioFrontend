import Foundation

struct SavedPlace: Identifiable {
    let id: UUID
    let name: String
    let address: String
}

protocol SavedPlacesLoading {
    func loadSavedPlaces() async throws -> [SavedPlace]
}
