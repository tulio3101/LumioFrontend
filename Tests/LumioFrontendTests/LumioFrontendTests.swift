import Foundation
import Testing
@testable import LumioFrontend

@Test func expirationIncludesDeadline() {
    let deadline = Date(timeIntervalSince1970: 100)
    let message = AudioMessage(text: "Giro", priority: .routeInformation, expiresAt: deadline)
    #expect(!message.isExpired(at: deadline.addingTimeInterval(-1)))
    #expect(message.isExpired(at: deadline))
}

@Test func messagesWithoutDeadlineDoNotExpireAutomatically() {
    let message = AudioMessage(text: "Entorno", priority: .environmentInformation)
    #expect(!message.isExpired(at: .distantFuture))
}

@Test @MainActor func navigationStubDoesNotInventRoutes() async {
    let service = UnavailableNavigationService()
    do {
        _ = try await service.createRoute(to: .query("Universidad"))
        Issue.record("Sin MapKit no debe devolverse una ruta ficticia")
    } catch FeatureUnavailable.navigation {
        // Esperado en plataformas sin MapKit/CoreLocation.
    } catch {
        Issue.record("Error inesperado: \(error)")
    }
    #expect(await service.restoreActiveRoute() == nil)
}
