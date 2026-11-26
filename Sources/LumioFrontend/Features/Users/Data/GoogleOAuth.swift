import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// OAuth 2.0 de Google para apps nativas (código de autorización con PKCE), el mismo flujo
/// que usa el SDK de Google, sin dependencias: la pantalla de Google la abre
/// ASWebAuthenticationSession y el código se cambia por el ID token en el endpoint de tokens.
/// Un client ID de tipo iOS no tiene secreto; PKCE protege el intercambio.
struct GoogleOAuthConfiguration: Equatable, Sendable {
    /// Client ID de tipo iOS, p. ej. `1234-abc.apps.googleusercontent.com`.
    let clientID: String

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let scopes = "openid email profile"

    /// Solo client IDs de Google bien formados; si no, Google no está configurado.
    init?(clientID: String?) {
        guard let clientID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines),
              clientID.hasSuffix(".apps.googleusercontent.com"),
              clientID.count > ".apps.googleusercontent.com".count
        else { return nil }
        self.clientID = clientID
    }

    /// Esquema del client ID invertido (`com.googleusercontent.apps.1234-abc`), que Google
    /// acepta como redirección para clientes iOS.
    var callbackScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    var redirectURI: String { "\(callbackScheme):/oauth2redirect" }
}

/// Un intento de inicio de sesión: verificador PKCE, `state` contra CSRF y `nonce`.
struct GoogleAuthorizationRequest: Equatable, Sendable {
    let configuration: GoogleOAuthConfiguration
    let codeVerifier: String
    let state: String
    let nonce: String

    init(
        configuration: GoogleOAuthConfiguration,
        codeVerifier: String = GoogleAuthorizationRequest.randomToken(),
        state: String = GoogleAuthorizationRequest.randomToken(byteCount: 16),
        nonce: String = GoogleAuthorizationRequest.randomToken(byteCount: 16)
    ) {
        self.configuration = configuration
        self.codeVerifier = codeVerifier
        self.state = state
        self.nonce = nonce
    }

    var authorizationURL: URL {
        var components = URLComponents(
            url: GoogleOAuthConfiguration.authorizationEndpoint, resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleOAuthConfiguration.scopes),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components.url!
    }

    /// Código de autorización de la redirección. `access_denied` es que la persona canceló.
    func authorizationCode(from callback: URL) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied" ? GoogleSignInFailure.cancelled : GoogleSignInFailure.server
        }
        guard value("state") == state, let code = value("code"), !code.isEmpty else {
            throw GoogleSignInFailure.server
        }
        return code
    }

    /// POST al endpoint de tokens con el código y el verificador PKCE.
    func tokenRequest(code: String, timeout: TimeInterval = 15) -> URLRequest {
        var request = URLRequest(url: GoogleOAuthConfiguration.tokenEndpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let fields = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", configuration.clientID),
            ("redirect_uri", configuration.redirectURI),
            ("code_verifier", codeVerifier),
        ]
        request.httpBody = fields
            .map { "\($0.0)=\(Self.formEncoded($0.1))" }
            .joined(separator: "&")
            .data(using: .utf8)
        return request
    }

    static func idToken(fromTokenResponse data: Data) throws -> GoogleIDToken {
        guard let response = try? JSONDecoder().decode(GoogleTokenResponseDTO.self, from: data),
              !response.idToken.isEmpty
        else { throw GoogleSignInFailure.server }
        return GoogleIDToken(value: response.idToken)
    }

    // MARK: PKCE

    /// base64url sin relleno de `byteCount` bytes aleatorios (32 → 43 caracteres, lo que pide
    /// RFC 7636 para el verificador).
    static func randomToken(byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    static func codeChallenge(for verifier: String) -> String {
        #if canImport(CryptoKit)
        return base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        #else
        return verifier
        #endif
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Solo los caracteres sin reservar de RFC 3986, en ASCII; todo lo demás se codifica.
    private static let formAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func formEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
    }
}

/// Respuesta del endpoint de tokens de Google; solo interesa el ID token.
struct GoogleTokenResponseDTO: Decodable, Equatable {
    let idToken: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
    }
}
