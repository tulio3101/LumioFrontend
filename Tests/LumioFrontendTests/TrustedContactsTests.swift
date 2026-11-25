import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumioFrontend

/// Configurar Contactos de Confianza (SCRUM-319): reglas, servicio con dobles, cliente del
/// backend y el flujo integrado con el AudioArbiter real.

private let baseURL = URL(string: "http://localhost:8000")!
private let mariaID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let pedroID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
private let maria = TrustedContact(id: mariaID, name: "María Gómez", email: "maria@example.com")
private let pedro = TrustedContact(id: pedroID, name: "Pedro", email: "pedro@example.com")

private func contactJSON(_ contact: TrustedContact) -> String {
    """
    {"id":"\(contact.id.uuidString.lowercased())","name":"\(contact.name)","email":"\(contact.email)",\
    "created_at":"2026-11-24T10:00:00Z"}
    """
}

private func listJSON(_ contacts: [TrustedContact]) -> Data {
    Data("[\(contacts.map(contactJSON).joined(separator: ","))]".utf8)
}

@MainActor
final class FakeContactsRemote: TrustedContactsRemoting {
    var stored: [TrustedContact] = [maria, pedro]
    var listResult: Result<Void, Error> = .success(())
    var writeResult: Result<Void, Error> = .success(())
    var deleteResult: Result<Void, Error> = .success(())
    private(set) var added: [ContactDraft] = []
    private(set) var updated: [(id: UUID, draft: ContactDraft)] = []
    private(set) var deleted: [UUID] = []

    func listContacts() async throws -> [TrustedContact] {
        try listResult.get()
        return stored
    }

    func addContact(_ draft: ContactDraft) async throws -> TrustedContact {
        added.append(draft)
        try writeResult.get()
        return TrustedContact(id: UUID(), name: draft.name, email: draft.email)
    }

    func updateContact(id: UUID, _ draft: ContactDraft) async throws -> TrustedContact {
        updated.append((id, draft))
        try writeResult.get()
        return TrustedContact(id: id, name: draft.name, email: draft.email)
    }

    func deleteContact(id: UUID) async throws {
        deleted.append(id)
        try deleteResult.get()
    }
}

@MainActor
private struct ContactsHarness {
    let remote = FakeContactsRemote()
    let arbiter = SpyArbiter()
    let tokens = InMemoryTokenStore(AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
    let service: TrustedContactsService

    init() {
        service = TrustedContactsService(remote: remote, tokens: tokens, arbiter: arbiter)
    }

    var lastSpoken: String? { arbiter.received.last?.text }

    func loaded() async -> ContactsHarness {
        _ = await service.loadContacts()
        return self
    }
}

// MARK: - Reglas

@Test func validContactsPass() {
    for (name, email) in [
        ("María Gómez", "maria@example.com"), ("  O'Neill-Pérez Jr. ", "  Maria.Gomez@Example.COM "),
        ("Ñ" + String(repeating: "á", count: 59), "a@b.co"),
    ] {
        #expect(ContactsPolicy.validate(name: name, email: email, existing: []) == ContactValidation(), "\(name) \(email)")
    }
}

@Test func nameIsRequiredAndFollowsTheAccountNameRules() {
    #expect(ContactsPolicy.validate(name: "", email: "a@b.co", existing: []).name == .missing)
    #expect(ContactsPolicy.validate(name: "   ", email: "a@b.co", existing: []).name == .missing)
    #expect(ContactsPolicy.validate(name: "R2-D2", email: "a@b.co", existing: []).name == .invalidCharacters)
    #expect(ContactsPolicy.validate(name: "...", email: "a@b.co", existing: []).name == .invalidCharacters)
    #expect(ContactsPolicy.validate(name: String(repeating: "a", count: 61), email: "a@b.co", existing: []).name
        == .tooLong(maximum: 60))
}

@Test func invalidEmailsAreRejected() {
    #expect(ContactsPolicy.validate(name: "Ana", email: "", existing: []).email == .missing)
    #expect(ContactsPolicy.validate(name: "Ana", email: "   ", existing: []).email == .missing)
    for email in ["maria", "maria@", "@example.com", "maria@example", "mar ia@example.com", "a@b@c.com", "a@.com"] {
        #expect(ContactsPolicy.validate(name: "Ana", email: email, existing: []).email == .invalidFormat, "\(email)")
    }
}

@Test func repeatedEmailsAreRejectedIgnoringCase() {
    let validation = ContactsPolicy.validate(name: "Otra", email: " MARIA@example.com ", existing: [maria, pedro])

    #expect(validation.email == .duplicate(ofName: "María Gómez"))
    #expect(validation.firstInvalidField == .email)
}

@Test func editingAContactMayKeepItsOwnEmailButNotTakeAnothers() {
    #expect(ContactsPolicy.validate(name: "Mari", email: "maria@example.com", existing: [maria, pedro], editing: maria)
        == ContactValidation())
    #expect(ContactsPolicy.validate(name: "Mari", email: "pedro@example.com", existing: [maria, pedro], editing: maria).email
        == .duplicate(ofName: "Pedro"))
}

@Test func contactsValuesAreNormalizedLikeTheBackend() {
    #expect(ContactsPolicy.draft(name: "  Ana   María ", email: "  Ana@Example.COM ")
        == ContactDraft(name: "Ana María", email: "ana@example.com"))
    // «é» escrita con tilde combinante se envía compuesta.
    #expect(ContactsPolicy.normalizedName("Jose\u{301}")?.unicodeScalars.count == 4)
}

@Test func contactsFirstInvalidFieldFollowsTheScreenOrder() {
    let validation = ContactsPolicy.validate(name: "R2", email: "x", existing: [])

    #expect(validation.firstInvalidField == .name)
    #expect(ContactAnnouncements.messages(for: validation).count == 2)
}

@Test func theLimitMatchesTheBackend() {
    #expect(ContactsPolicy.maximumContacts == 5)
    let full = (0..<5).map { TrustedContact(id: UUID(), name: "C", email: "c\($0)@example.com") }
    #expect(ContactsPolicy.isFull(full))
    #expect(!ContactsPolicy.isFull(Array(full.dropLast())))
}

// MARK: - Consultar

@Test @MainActor func contactsAreLoadedWithoutSpeaking() async {
    let harness = ContactsHarness()

    let result = await harness.service.loadContacts()

    #expect(result == .success([maria, pedro]))
    #expect(harness.service.contacts == [maria, pedro])
    #expect(harness.arbiter.received.isEmpty)
}

@Test @MainActor func contactsLoadFailureIsSpoken() async {
    let harness = ContactsHarness()
    harness.remote.listResult = .failure(URLError(.notConnectedToInternet))

    let result = await harness.service.loadContacts()

    #expect(result == .failure(.offline))
    #expect(harness.lastSpoken == "Sin conexión. No se pudo consultar tus contactos. Intenta de nuevo cuando tengas conexión.")
    #expect(harness.arbiter.received.last?.contextID == TrustedContactsService.contextID)
}

// MARK: - Agregar

@Test @MainActor func validContactIsAddedAndAnnounced() async {
    let harness = await ContactsHarness().loaded()

    let outcome = await harness.service.addContact(name: " Luis   Mora ", email: " LUIS@Example.com ")

    guard case .saved(let saved) = outcome else {
        Issue.record("Se esperaba .saved, llegó \(outcome)")
        return
    }
    #expect(harness.remote.added == [ContactDraft(name: "Luis Mora", email: "luis@example.com")])
    #expect(harness.service.contacts.last == saved)
    #expect(harness.service.contacts.count == 3)
    #expect(harness.lastSpoken == "Contacto guardado: Luis Mora, luis@example.com.")
}

@Test @MainActor func invalidContactIsNotSentAndIsSpoken() async {
    let harness = await ContactsHarness().loaded()

    let outcome = await harness.service.addContact(name: "", email: "no-es-correo")

    guard case .invalid(let validation) = outcome else {
        Issue.record("Se esperaba .invalid, llegó \(outcome)")
        return
    }
    #expect(validation.name == .missing)
    #expect(validation.email == .invalidFormat)
    #expect(harness.remote.added.isEmpty)
    #expect(harness.lastSpoken == "No se guardó el contacto. Escribe el nombre del contacto. "
        + "El correo no es válido. Revisa que tenga el formato nombre@dominio.com.")
}

@Test @MainActor func repeatedEmailIsNotSentAndNamesTheOwner() async {
    let harness = await ContactsHarness().loaded()

    let outcome = await harness.service.addContact(name: "Otra", email: "PEDRO@example.com")

    #expect(outcome == .invalid(ContactValidation(name: nil, email: .duplicate(ofName: "Pedro"))))
    #expect(harness.remote.added.isEmpty)
    #expect(harness.lastSpoken == "No se guardó el contacto. Ese correo ya es de tu contacto Pedro.")
}

@Test @MainActor func reachingTheLimitIsNotSentAndIsSpoken() async {
    let harness = ContactsHarness()
    harness.remote.stored = (0..<5).map { TrustedContact(id: UUID(), name: "Contacto", email: "c\($0)@example.com") }
    _ = await harness.service.loadContacts()

    let outcome = await harness.service.addContact(name: "Uno más", email: "mas@example.com")

    #expect(outcome == .limitReached)
    #expect(harness.remote.added.isEmpty)
    #expect(harness.lastSpoken == ContactAnnouncements.limitReached)
}

@Test @MainActor func failedAddKeepsTheListAndIsSpoken() async {
    let harness = await ContactsHarness().loaded()
    harness.remote.writeResult = .failure(HTTPClientError.statusCode(503))

    let outcome = await harness.service.addContact(name: "Luis", email: "luis@example.com")

    #expect(outcome == .failed(.server))
    #expect(harness.service.contacts == [maria, pedro])
    #expect(harness.lastSpoken == "No se pudo guardar el contacto. Intenta de nuevo más tarde. Tus contactos siguen como estaban.")
}

@Test @MainActor func conflictAndRejectionFromTheServerAreSpoken() async {
    let harness = await ContactsHarness().loaded()

    harness.remote.writeResult = .failure(HTTPClientError.statusCode(409))
    #expect(await harness.service.addContact(name: "Luis", email: "luis@example.com") == .failed(.conflict))
    #expect(harness.lastSpoken?.contains("ese correo ya está en tu lista o ya tienes 5 contactos") == true)

    harness.remote.writeResult = .failure(HTTPClientError.statusCode(422))
    #expect(await harness.service.addContact(name: "Luis", email: "luis@example.com") == .failed(.rejected))
    #expect(harness.lastSpoken?.contains("que no sea tu propio correo") == true)
}

@Test @MainActor func offlineAddIsSpoken() async {
    let harness = await ContactsHarness().loaded()
    harness.remote.writeResult = .failure(URLError(.networkConnectionLost))

    #expect(await harness.service.addContact(name: "Luis", email: "luis@example.com") == .failed(.offline))
    #expect(harness.lastSpoken?.hasPrefix("Sin conexión.") == true)
}

@Test @MainActor func contactsExpiredSessionClearsTheTokens() async {
    let harness = await ContactsHarness().loaded()
    harness.remote.writeResult = .failure(AuthenticationError.sessionExpired)

    #expect(await harness.service.addContact(name: "Luis", email: "luis@example.com") == .failed(.sessionExpired))
    #expect(harness.tokens.load() == nil)
    #expect(harness.lastSpoken == ContactAnnouncements.sessionExpired)
}

// MARK: - Editar

@Test @MainActor func contactIsEditedAndAnnounced() async {
    let harness = await ContactsHarness().loaded()

    let outcome = await harness.service.updateContact(maria, name: "María José", email: "mj@example.com")

    let expected = TrustedContact(id: mariaID, name: "María José", email: "mj@example.com")
    #expect(outcome == .saved(expected))
    #expect(harness.remote.updated.map(\.id) == [mariaID])
    #expect(harness.remote.updated.map(\.draft) == [ContactDraft(name: "María José", email: "mj@example.com")])
    #expect(harness.service.contacts == [expected, pedro])
    #expect(harness.lastSpoken == "Contacto actualizado: María José, mj@example.com.")
}

@Test @MainActor func editingWithoutChangesIsNotSent() async {
    let harness = await ContactsHarness().loaded()

    let outcome = await harness.service.updateContact(maria, name: " María  Gómez ", email: "MARIA@example.com")

    #expect(outcome == .unchanged)
    #expect(harness.remote.updated.isEmpty)
    #expect(harness.lastSpoken == "No hay cambios para guardar.")
}

@Test @MainActor func editingCannotTakeAnotherContactsEmail() async {
    let harness = await ContactsHarness().loaded()

    let outcome = await harness.service.updateContact(maria, name: "María", email: "pedro@example.com")

    #expect(outcome == .invalid(ContactValidation(name: nil, email: .duplicate(ofName: "Pedro"))))
    #expect(harness.remote.updated.isEmpty)
}

@Test @MainActor func editingIsAllowedWhenTheListIsFull() async {
    let harness = ContactsHarness()
    harness.remote.stored = (0..<5).map { TrustedContact(id: UUID(), name: "Contacto", email: "c\($0)@example.com") }
    _ = await harness.service.loadContacts()
    let first = harness.service.contacts[0]

    let outcome = await harness.service.updateContact(first, name: "Nuevo nombre", email: first.email)

    #expect(outcome == .saved(TrustedContact(id: first.id, name: "Nuevo nombre", email: first.email)))
}

@Test @MainActor func failedEditKeepsTheContact() async {
    let harness = await ContactsHarness().loaded()
    harness.remote.writeResult = .failure(HTTPClientError.statusCode(500))

    let outcome = await harness.service.updateContact(maria, name: "Mari", email: "maria@example.com")

    #expect(outcome == .failed(.server))
    #expect(harness.service.contacts == [maria, pedro])
}

// MARK: - Eliminar

@Test @MainActor func contactIsDeletedAndAnnounced() async {
    let harness = await ContactsHarness().loaded()

    let outcome = await harness.service.deleteContact(maria)

    #expect(outcome == .deleted)
    #expect(harness.remote.deleted == [mariaID])
    #expect(harness.service.contacts == [pedro])
    #expect(harness.lastSpoken == "Contacto eliminado: María Gómez.")
}

@Test @MainActor func failedDeleteKeepsTheContactAndIsSpoken() async {
    let harness = await ContactsHarness().loaded()
    harness.remote.deleteResult = .failure(HTTPClientError.statusCode(500))

    let outcome = await harness.service.deleteContact(maria)

    #expect(outcome == .failed(.server))
    #expect(harness.service.contacts == [maria, pedro])
    #expect(harness.lastSpoken == "No se pudo eliminar el contacto. Intenta de nuevo más tarde. Sigue en tu lista.")
}

@Test @MainActor func deletingAContactThatNoLongerExistsDropsItFromTheList() async {
    let harness = await ContactsHarness().loaded()
    harness.remote.deleteResult = .failure(HTTPClientError.statusCode(404))

    #expect(await harness.service.deleteContact(maria) == .failed(.notFound))
    #expect(harness.service.contacts == [pedro])
}

@Test @MainActor func contactsANewMessageReplacesThePreviousOne() async {
    let harness = await ContactsHarness().loaded()

    _ = await harness.service.addContact(name: "", email: "x")
    _ = await harness.service.addContact(name: "Luis", email: "luis@example.com")

    #expect(harness.arbiter.cancelledContexts.last == [TrustedContactsService.contextID])
    #expect(harness.lastSpoken == "Contacto guardado: Luis, luis@example.com.")
}

@Test func contactsBackendErrorsAreClassified() {
    #expect(TrustedContactsService.failure(for: URLError(.notConnectedToInternet)) == .offline)
    #expect(TrustedContactsService.failure(for: URLError(.badServerResponse)) == .server)
    #expect(TrustedContactsService.failure(for: AuthenticationError.sessionExpired) == .sessionExpired)
    #expect(TrustedContactsService.failure(for: AuthenticationError.notSignedIn) == .sessionExpired)
    #expect(TrustedContactsService.failure(for: HTTPClientError.statusCode(401)) == .sessionExpired)
    #expect(TrustedContactsService.failure(for: HTTPClientError.statusCode(404)) == .notFound)
    #expect(TrustedContactsService.failure(for: HTTPClientError.statusCode(409)) == .conflict)
    #expect(TrustedContactsService.failure(for: HTTPClientError.statusCode(422)) == .rejected)
    #expect(TrustedContactsService.failure(for: HTTPClientError.statusCode(500)) == .server)
    #expect(TrustedContactsService.failure(for: FeatureUnavailable.authentication) == .server)
}

@Test func rowsAreReadAsNameAndEmail() {
    #expect(ContactAnnouncements.summary(of: maria) == "María Gómez, maria@example.com")
}

// MARK: - Backend

private func json(_ request: URLRequest?) throws -> [String: Any] {
    let body = try #require(request?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
}

@Test func listReadsContacts() async throws {
    let http = FakeHTTPClient(response: .success(listJSON([maria, pedro])))

    let contacts = try await RemoteTrustedContactsService(client: http, baseURL: baseURL).listContacts()

    #expect(contacts == [maria, pedro])
    #expect(http.requests.first?.httpMethod == "GET")
    #expect(http.requests.first?.url?.absoluteString == "http://localhost:8000/contacts")
}

@Test func addPostsNameAndEmail() async throws {
    let http = FakeHTTPClient(response: .success(Data(contactJSON(maria).utf8)))

    let created = try await RemoteTrustedContactsService(client: http, baseURL: baseURL)
        .addContact(ContactDraft(name: "María Gómez", email: "maria@example.com"))

    #expect(created == maria)
    let request = try #require(http.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/contacts")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(try json(request) as? [String: String] == ["name": "María Gómez", "email": "maria@example.com"])
}

@Test func updatePutsToTheContactPath() async throws {
    let http = FakeHTTPClient(response: .success(Data(contactJSON(maria).utf8)))

    _ = try await RemoteTrustedContactsService(client: http, baseURL: baseURL)
        .updateContact(id: mariaID, ContactDraft(name: "María Gómez", email: "maria@example.com"))

    let request = try #require(http.requests.first)
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.path == "/contacts/11111111-1111-1111-1111-111111111111")
    #expect(try json(request).keys.sorted() == ["email", "name"])
}

@Test func deleteSendsDeleteToTheContactPath() async throws {
    let http = FakeHTTPClient(response: .success(Data()))

    try await RemoteTrustedContactsService(client: http, baseURL: baseURL).deleteContact(id: pedroID)

    let request = try #require(http.requests.first)
    #expect(request.httpMethod == "DELETE")
    #expect(request.url?.path == "/contacts/22222222-2222-2222-2222-222222222222")
    #expect(request.httpBody == nil)
}

@Test func withoutBackendContactsAreUnavailable() async {
    let remote = RemoteTrustedContactsService(client: FakeHTTPClient(response: .success(Data())), baseURL: nil)

    await #expect(throws: FeatureUnavailable.self) { try await remote.listContacts() }
}

// MARK: - Flujo integrado (AudioArbiter real y sesión con refresh)

@MainActor
private struct ContactsFlow {
    let player = FakeAudioPlayer()
    let arbiter: AudioArbiterService
    let http: FakeHTTPClient
    let tokens = InMemoryTokenStore(AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
    let service: TrustedContactsService

    init(backend: Result<Data, Error>) {
        arbiter = AudioArbiterService(player: player)
        http = FakeHTTPClient(response: backend)
        let authorized = AuthorizedHTTPClient(
            base: http, api: AuthAPI(client: http, baseURL: baseURL), store: tokens
        )
        service = TrustedContactsService(
            remote: RemoteTrustedContactsService(client: authorized, baseURL: baseURL), tokens: tokens, arbiter: arbiter
        )
    }

    var spoken: String? { arbiter.currentMessage?.text }
}

@Test @MainActor func contactIsLoadedAddedEditedAndDeletedWithTheSession() async throws {
    let flow = ContactsFlow(backend: .success(listJSON([maria])))
    #expect(try await flow.service.loadContacts().get() == [maria])

    flow.http.response = .success(Data(contactJSON(pedro).utf8))
    let added = await flow.service.addContact(name: "Pedro", email: "pedro@example.com")
    #expect(added == .saved(pedro))
    #expect(flow.spoken == "Contacto guardado: Pedro, pedro@example.com.")

    let renamed = TrustedContact(id: pedroID, name: "Pedro Pérez", email: "pedro@example.com")
    flow.http.response = .success(Data(contactJSON(renamed).utf8))
    #expect(await flow.service.updateContact(pedro, name: "Pedro Pérez", email: "pedro@example.com") == .saved(renamed))
    #expect(flow.spoken == "Contacto actualizado: Pedro Pérez, pedro@example.com.")

    flow.http.response = .success(Data())
    #expect(await flow.service.deleteContact(renamed) == .deleted)
    #expect(flow.spoken == "Contacto eliminado: Pedro Pérez.")

    #expect(flow.http.requests.map(\.httpMethod) == ["GET", "POST", "PUT", "DELETE"])
    #expect(flow.http.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-1" })
    #expect(flow.service.contacts == [maria])
}

@Test @MainActor func invalidContactNeverReachesTheBackend() async {
    let flow = ContactsFlow(backend: .success(listJSON([])))
    _ = await flow.service.loadContacts()

    let outcome = await flow.service.addContact(name: "Ana", email: "ana@")

    #expect(outcome == .invalid(ContactValidation(name: nil, email: .invalidFormat)))
    #expect(flow.http.requests.map(\.httpMethod) == ["GET"])
    #expect(flow.spoken == "No se guardó el contacto. El correo no es válido. Revisa que tenga el formato nombre@dominio.com.")
}

@Test @MainActor func contactsExpiredAccessTokenIsRenewedBeforeSaving() async throws {
    let flow = ContactsFlow(backend: .success(listJSON([])))
    _ = await flow.service.loadContacts()
    let tokenPair = Data("""
    {"access_token":"access-2","refresh_token":"refresh-2","token_type":"bearer","expires_in":900}
    """.utf8)
    flow.http.queued = [.failure(HTTPClientError.statusCode(401)), .success(tokenPair)]
    flow.http.response = .success(Data(contactJSON(maria).utf8))

    let outcome = await flow.service.addContact(name: "María Gómez", email: "maria@example.com")

    #expect(outcome == .saved(maria))
    #expect(flow.http.requests.map { $0.url?.path } == ["/contacts", "/contacts", "/users/refresh", "/contacts"])
    #expect(flow.http.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
}

@Test @MainActor func contactsRejectedSessionClearsTokensAndIsSpoken() async {
    let flow = ContactsFlow(backend: .failure(HTTPClientError.statusCode(401)))

    let result = await flow.service.loadContacts()

    #expect(result == .failure(.sessionExpired))
    #expect(flow.tokens.load() == nil)
    #expect(flow.spoken == "Tu sesión expiró. Inicia sesión de nuevo.")
}

@Test @MainActor func serverErrorOnSaveKeepsTheListAndIsSpoken() async {
    let flow = ContactsFlow(backend: .success(listJSON([maria])))
    _ = await flow.service.loadContacts()
    flow.http.response = .failure(HTTPClientError.statusCode(500))

    let outcome = await flow.service.addContact(name: "Pedro", email: "pedro@example.com")

    #expect(outcome == .failed(.server))
    #expect(flow.service.contacts == [maria])
    #expect(flow.spoken?.contains("Tus contactos siguen como estaban.") == true)
}
