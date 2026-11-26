#if os(iOS) && canImport(AuthenticationServices)
import AuthenticationServices
import UIKit

/// Abre la pantalla de inicio de sesión de Google con ASWebAuthenticationSession (hoja del
/// sistema, accesible con VoiceOver y que comparte la sesión de Google de Safari) y cambia
/// el código por el ID token. No guarda nada: los tokens de Lumio los guarda quien llama.
final class WebGoogleIDTokenProvider: NSObject, GoogleIDTokenProviding,
    ASWebAuthenticationPresentationContextProviding {
    private let configuration: GoogleOAuthConfiguration
    private let client: any HTTPClient
    /// La sesión debe vivir mientras la hoja está abierta.
    private var session: ASWebAuthenticationSession?
    /// Ventana sobre la que se presenta la hoja; se elige en el hilo principal antes de abrirla.
    private var anchor: ASPresentationAnchor?

    init(configuration: GoogleOAuthConfiguration, client: any HTTPClient) {
        self.configuration = configuration
        self.client = client
    }

    func requestIDToken() async throws -> GoogleIDToken {
        let request = GoogleAuthorizationRequest(configuration: configuration)
        let callback = try await authorize(request)
        let code = try request.authorizationCode(from: callback)
        do {
            let data = try await client.send(request.tokenRequest(code: code))
            return try GoogleAuthorizationRequest.idToken(fromTokenResponse: data)
        } catch HTTPClientError.statusCode(_) {
            // Código vencido o ya usado: se trata como un error de Google, no de Lumio.
            throw GoogleSignInFailure.server
        }
    }

    @MainActor
    private func authorize(_ request: GoogleAuthorizationRequest) async throws -> URL {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        anchor = windows.first(where: \.isKeyWindow) ?? windows.first ?? UIWindow()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: request.authorizationURL,
                callbackURLScheme: configuration.callbackScheme
            ) { [weak self] url, error in
                self?.session = nil
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: GoogleSignInFailure.cancelled)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: GoogleSignInFailure.server)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: GoogleSignInFailure.server)
            }
        }
    }

    /// Solo devuelve la ventana ya elegida en `authorize`, que siempre corre antes.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let anchor else { preconditionFailure("La ventana se elige antes de abrir Google.") }
        return anchor
    }
}
#endif
