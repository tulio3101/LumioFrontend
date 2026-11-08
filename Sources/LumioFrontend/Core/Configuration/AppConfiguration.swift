import Foundation

/// Valores por entorno leídos del Info.plist. No incluir secretos.
struct AppConfiguration: Equatable {
    /// LumioAPIBaseURL, p. ej. http://192.168.1.10:8000 (la IP del Mac en un iPhone físico).
    let apiBaseURL: URL?
    /// LumioDevUserID: PROVISIONAL hasta el login. UUID impreso por
    /// `python -m app.scripts.seed_dev_user` en el backend.
    let devUserID: UUID?

    init(info: [String: Any]) {
        apiBaseURL = (info["LumioAPIBaseURL"] as? String)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
        devUserID = (info["LumioDevUserID"] as? String)
            .flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
    }

    static var main: AppConfiguration {
        AppConfiguration(info: Bundle.main.infoDictionary ?? [:])
    }
}
