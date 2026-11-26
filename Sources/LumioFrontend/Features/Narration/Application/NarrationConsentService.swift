import Foundation

/// SCRUM-324: Consentir el Envío de Imágenes para la Narración.
///
/// - La decisión vive solo en el teléfono y se conserva entre sesiones (`NarrationConsentStoring`).
/// - Sin consentimiento vigente `consentVersionForUpload` es nil: la narración nunca llama al
///   endpoint y el resto de la app funciona igual.
/// - Revocar corta la narración que suene o espere (contexto `narration`) y avisa a
///   `onRevoked` para cancelar la solicitud en vuelo y apagar la narración automática.
/// - Todo lo que dice pasa por el AudioArbiter como P2: una alerta P1 lo interrumpe.
@MainActor
final class NarrationConsentService: ObservableObject, NarrationConsentManaging, NarrationConsentChecking {
    static let contextID = "narration-consent"

    @Published private(set) var status: NarrationConsentStatus
    /// La narración (SCRUM-38) cancela aquí la solicitud en vuelo al revocar.
    var onRevoked: (() -> Void)?

    private let store: any NarrationConsentStoring
    private let arbiter: (any AudioArbitrating)?
    private let now: () -> Date

    init(
        store: any NarrationConsentStoring,
        arbiter: (any AudioArbitrating)?,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.arbiter = arbiter
        self.now = now
        // Un archivo ilegible cuenta como no preguntado: nunca se asume un consentimiento.
        status = NarrationConsentPolicy.status(of: (try? store.load()) ?? nil)
    }

    var hasConsent: Bool { status == .granted }

    var consentVersionForUpload: String? {
        hasConsent ? NarrationConsentPolicy.currentVersion : nil
    }

    func explain() {
        say(NarrationConsentPolicy.explanation + " " + NarrationConsentPolicy.question, key: "explanation")
    }

    /// SCRUM-38/39, antes de la primera narración. true si ya se puede narrar; si no, lo
    /// explica (si nunca se preguntó o cambió el aviso) o recuerda dónde activarlo.
    @discardableResult
    func requireConsentBeforeNarration() -> Bool {
        switch status {
        case .granted: return true
        case .notAsked, .outdated: explain()
        case .declined: say(NarrationConsentPolicy.required, key: "required")
        }
        return false
    }

    @discardableResult
    func accept() -> Bool {
        save(granted: true, announcing: NarrationConsentPolicy.accepted)
    }

    @discardableResult
    func decline() -> Bool {
        save(granted: false, announcing: NarrationConsentPolicy.declined)
    }

    @discardableResult
    func revoke() -> Bool {
        let wasGranted = status == .granted || status == .outdated
        guard save(granted: false, announcing: NarrationConsentPolicy.revoked) else { return false }
        if wasGranted {
            // Lo que ya se describió con el consentimiento anterior tampoco se reproduce.
            arbiter?.cancel(contextIDs: [NarrationAudio.contextID])
            onRevoked?()
        }
        return true
    }

    private func save(granted: Bool, announcing text: String) -> Bool {
        let consent = NarrationConsent(
            granted: granted, version: NarrationConsentPolicy.currentVersion, decidedAt: now()
        )
        do {
            try store.save(consent)
        } catch {
            say(NarrationConsentPolicy.saveFailed, key: "save-failed")
            return false
        }
        status = NarrationConsentPolicy.status(of: consent)
        say(text, key: "result")
        return true
    }

    private func say(_ text: String, key: String) {
        guard let arbiter else { return }
        // Una explicación o un resultado nuevo reemplaza al anterior que aún no terminó.
        arbiter.cancel(contextIDs: [Self.contextID])
        arbiter.receive(AudioMessage(
            text: text,
            priority: .routeInformation,
            createdAt: now(),
            expiresAt: now().addingTimeInterval(60),
            contextID: Self.contextID,
            deduplicationKey: key
        ))
    }
}

/// La decisión en un JSON dentro de Application Support, junto a las preferencias.
struct FileNarrationConsentStore: NarrationConsentStoring {
    let fileURL: URL

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Lumio", isDirectory: true)
            .appendingPathComponent("narration-consent.json")
    }

    func load() throws -> NarrationConsent? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NarrationConsent.self, from: Data(contentsOf: fileURL))
    }

    func save(_ consent: NarrationConsent) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(consent).write(to: fileURL, options: options)
    }
}
