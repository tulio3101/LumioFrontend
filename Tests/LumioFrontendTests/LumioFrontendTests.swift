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

@Test func narrationDecodesBackendContract() throws {
    let data = Data(#"{"text":"Hay un parque","language":"es","priority":"normal"}"#.utf8)
    let response = try JSONDecoder().decode(NarrationResponseDTO.self, from: data)
    #expect(response.text == "Hay un parque")
    #expect(response.priority == .normal)
}

@Test func navigationStubDoesNotInventRoutes() async {
    do {
        _ = try await UnavailableNavigationService().planRoute(to: "Universidad")
        Issue.record("El scaffold no debe devolver una ruta ficticia")
    } catch FeatureUnavailable.navigation {
        // Esperado hasta integrar MapKit.
    } catch {
        Issue.record("Error inesperado: \(error)")
    }
}
