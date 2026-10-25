import Foundation

struct UserProfile: Identifiable {
    let id: UUID
    let email: String
}

protocol UserProfileLoading {
    func loadCurrentUser() async throws -> UserProfile
}
