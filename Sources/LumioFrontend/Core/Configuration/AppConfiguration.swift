import Foundation

/// Valores por entorno leídos del Info.plist. No incluir secretos.
struct AppConfiguration: Equatable {
    /// LumioAPIBaseURL, p. ej. http://192.168.1.10:8000 (la IP del equipo en un iPhone físico).
    let apiBaseURL: URL?
    /// GoogleClientID: client ID de tipo iOS (no es secreto). Vacío: Google no disponible.
    let google: GoogleOAuthConfiguration?

    init(info: [String: Any]) {
        apiBaseURL = (info["LumioAPIBaseURL"] as? String)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
        google = GoogleOAuthConfiguration(clientID: info["GoogleClientID"] as? String)
    }

    static var main: AppConfiguration {
        AppConfiguration(info: Bundle.main.infoDictionary ?? [:])
    }
}
