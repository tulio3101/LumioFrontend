import Foundation

/// SCRUM-32: preferencias de accesibilidad, con el mismo ciclo que las de vibración:
///
/// 1. Al abrir la app las lee del teléfono. Un archivo dañado se reemplaza por las
///    predeterminadas y se avisa en su pantalla.
/// 2. Los módulos las leen en memoria (`preferences`): la narración automática (SCRUM-40) y
///    el estado al abrir la app (Pantalla principal). Nunca esperan al disco ni a la red.
/// 3. Un cambio se aplica al instante y se guarda; si no se pudo guardar, se dice por audio.
@MainActor
final class AccessibilityPreferencesService: ObservableObject, AccessibilityPreferencesManaging,
    AccessibilityPreferencesResetting {
    static let contextID = "accessibility-preferences"

    @Published private(set) var preferences: AccessibilityPreferences
    private(set) var storedUnreadable: Bool

    private let store: any AccessibilityPreferencesStoring
    private let arbiter: (any AudioArbitrating)?
    private let now: () -> Date

    init(
        store: any AccessibilityPreferencesStoring,
        arbiter: (any AudioArbitrating)?,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.arbiter = arbiter
        self.now = now
        do {
            preferences = try store.load() ?? .standard
            storedUnreadable = false
        } catch {
            preferences = .standard
            storedUnreadable = true
        }
    }

    @discardableResult
    func update(_ new: AccessibilityPreferences) -> AccessibilityPreferencesOutcome {
        guard new != preferences else { return .unchanged }
        preferences = new
        storedUnreadable = false
        do {
            try store.save(new)
            return .saved
        } catch {
            speak(AccessibilityPreferencesAnnouncements.notSaved)
            return .appliedNotSaved
        }
    }

    /// Eliminar cuenta vuelve a las predeterminadas.
    func resetToStandard() {
        try? store.clear()
        storedUnreadable = false
        preferences = .standard
    }

    private func speak(_ text: String) {
        guard let arbiter else { return }
        arbiter.cancel(contextIDs: [Self.contextID])
        arbiter.receive(AudioMessage(
            text: text,
            priority: .routeInformation,
            createdAt: now(),
            expiresAt: now().addingTimeInterval(30),
            contextID: Self.contextID,
            deduplicationKey: "not-saved"
        ))
    }
}

/// En un JSON dentro de Application Support, junto a las de voz y vibración.
struct FileAccessibilityPreferencesStore: AccessibilityPreferencesStoring {
    let fileURL: URL

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Lumio", isDirectory: true)
            .appendingPathComponent("accessibility-preferences.json")
    }

    func load() throws -> AccessibilityPreferences? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(AccessibilityPreferences.self, from: Data(contentsOf: fileURL))
    }

    func save(_ preferences: AccessibilityPreferences) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(preferences).write(to: fileURL, options: options)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
