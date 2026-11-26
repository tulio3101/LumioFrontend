import Foundation

/// Personalizar Cuenta (SCRUM-6):
///
/// 1. Consulta la cuenta (correo, nombre y celular). Si falla, lo anuncia.
/// 2. Guardar valida primero en el teléfono (mismas reglas que el backend); con errores no
///    se envía nada y se locutan. Si nada cambió tampoco se envía.
/// 3. PATCH /users/me y «Cambios guardados.»; un fallo deja los datos como estaban.
/// 4. Cambiar la contraseña exige la actual y una confirmación; el backend cierra las
///    sesiones de los demás dispositivos y este sigue con la suya.
/// 5. SCRUM-62: asociar Google abre la pantalla de Google y envía el ID token a
///    POST /users/me/google.
///
/// Todo resultado y todo error se anuncia por el AudioArbiter (contexto `account-profile`).
@MainActor
final class ProfileService: ProfileManaging {
    static let contextID = "account-profile"

    private let remote: any ProfileRemoting
    /// Se borran si la sesión ya no vale, para que la app vuelva a pedir iniciar sesión.
    private let tokens: (any TokenStoring)?
    private let arbiter: (any AudioArbitrating)?
    /// SCRUM-62: pantalla de Google para asociar la cuenta; nil si no está configurado.
    private let google: (any GoogleIDTokenProviding)?
    private let connectivity: (any ConnectivityObserving)?
    private let now: () -> Date
    /// Lo último que se sabe guardado en el backend, para no enviar lo que no cambió.
    private(set) var current: UserProfile?

    init(
        remote: any ProfileRemoting,
        tokens: (any TokenStoring)? = nil,
        arbiter: (any AudioArbitrating)?,
        google: (any GoogleIDTokenProviding)? = nil,
        connectivity: (any ConnectivityObserving)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.remote = remote
        self.tokens = tokens
        self.arbiter = arbiter
        self.google = google
        self.connectivity = connectivity
        self.now = now
    }

    func loadProfile() async -> Result<UserProfile, ProfileFailure> {
        do {
            let profile = try await remote.loadProfile()
            current = profile
            return .success(profile)
        } catch {
            let failure = handle(error)
            speak(ProfileAnnouncements.loadFailed(failure), key: "load-failed")
            return .failure(failure)
        }
    }

    func saveProfile(displayName: String, phone: String) async -> ProfileSaveOutcome {
        let validation = ProfilePolicy.validate(displayName: displayName, phone: phone)
        guard validation.firstInvalidField == nil else {
            speak(ProfileAnnouncements.invalidProfile(validation), key: "invalid-profile")
            return .invalid(validation)
        }
        let changes = ProfilePolicy.changes(displayName: displayName, phone: phone)
        if let current, current.displayName == changes.displayName, current.phone == changes.phone {
            speak(ProfileAnnouncements.unchanged, key: "unchanged")
            return .unchanged
        }
        do {
            let saved = try await remote.updateProfile(changes)
            current = saved
            speak(ProfileAnnouncements.saved, key: "saved")
            return .saved(saved)
        } catch {
            let failure = handle(error)
            speak(ProfileAnnouncements.saveFailed(failure), key: "save-failed")
            return .failed(failure)
        }
    }

    func changePassword(current: String, new: String, confirmation: String) async -> PasswordChangeOutcome {
        let validation = PasswordChangePolicy.validate(current: current, new: new, confirmation: confirmation)
        guard validation.firstInvalidField == nil else {
            speak(ProfileAnnouncements.invalidPassword(validation), key: "invalid-password")
            return .invalid(validation)
        }
        do {
            try await remote.changePassword(current: current, new: new)
            speak(ProfileAnnouncements.passwordChanged, key: "password-changed")
            return .changed
        } catch {
            let failure = handle(error)
            speak(ProfileAnnouncements.passwordFailed(failure), key: "password-failed")
            return .failed(failure)
        }
    }

    /// SCRUM-62: asocia una cuenta de Google a esta cuenta de Lumio (también a una con
    /// contraseña). Sin red no abre Google. Cancelar o fallar no cambia nada; todo se anuncia.
    func linkGoogle() async -> GoogleLinkOutcome {
        guard let google else { return failLink(.unavailable) }
        if connectivity?.isConnected == false { return failLink(.offline) }
        do {
            let idToken = try await google.requestIDToken()
            let profile = try await remote.linkGoogle(idToken: idToken.value)
            current = profile
            speak(GoogleSignInAnnouncements.linked, key: "google-linked")
            return .linked(profile)
        } catch {
            let failure = GoogleSignInFailure.from(error)
            if failure == .sessionExpired { tokens?.clear() }
            return failLink(failure)
        }
    }

    private func failLink(_ failure: GoogleSignInFailure) -> GoogleLinkOutcome {
        speak(GoogleSignInAnnouncements.message(for: failure), key: "google-\(failure)")
        return .failed(failure)
    }

    private func handle(_ error: Error) -> ProfileFailure {
        let failure = Self.failure(for: error)
        if failure == .sessionExpired { tokens?.clear() }
        return failure
    }

    /// Un mensaje nuevo reemplaza al anterior del mismo flujo.
    private func speak(_ text: String, key: String) {
        guard let arbiter else { return }
        arbiter.cancel(contextIDs: [Self.contextID])
        arbiter.receive(AudioMessage(
            text: text,
            priority: .routeInformation,
            createdAt: now(),
            contextID: Self.contextID,
            deduplicationKey: key
        ))
    }

    nonisolated static func failure(for error: Error) -> ProfileFailure {
        switch error {
        case AuthenticationError.sessionExpired, AuthenticationError.notSignedIn,
             HTTPClientError.statusCode(401):
            return .sessionExpired
        case HTTPClientError.statusCode(403):
            return .wrongCurrentPassword
        case HTTPClientError.statusCode(409):
            return .passwordNotSet
        case HTTPClientError.statusCode(422):
            return .rejected
        case let error as URLError where error.isConnectivityFailure:
            return .offline
        default:
            return .server
        }
    }
}
