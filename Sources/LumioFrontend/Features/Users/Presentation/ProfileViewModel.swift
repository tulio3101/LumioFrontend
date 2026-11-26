#if canImport(SwiftUI)
import SwiftUI

/// Estado de la pantalla Mi cuenta. La validación, el envío y el audio los hace
/// ProfileService; aquí solo se reflejan en la pantalla. Como en el registro, los errores
/// de campo aparecen tras el primer intento y desde entonces se actualizan al escribir.
@MainActor
final class ProfileViewModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(ProfileFailure)
    }

    struct Banner: Equatable {
        let status: LumioStatus
        let title: String
        let message: String
    }

    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var email = ""
    @Published var displayName = "" { didSet { refreshProfileValidation() } }
    @Published var phone = "" { didSet { refreshProfileValidation() } }
    @Published private(set) var profileValidation = ProfileValidation()
    @Published private(set) var profileBanner: Banner?
    @Published private(set) var isSaving = false

    @Published var currentPassword = "" { didSet { refreshPasswordValidation() } }
    @Published var newPassword = "" { didSet { refreshPasswordValidation() } }
    @Published var confirmation = "" { didSet { refreshPasswordValidation() } }
    @Published private(set) var passwordValidation = PasswordChangeValidation()
    @Published private(set) var passwordBanner: Banner?
    @Published private(set) var isChangingPassword = false

    /// SCRUM-62: asociar una cuenta de Google.
    @Published private(set) var googleLinked = false
    @Published private(set) var googleBanner: Banner?
    @Published private(set) var isLinkingGoogle = false

    private var attemptedSave = false
    private var attemptedPasswordChange = false
    private let service: any ProfileManaging
    private let onSessionExpired: () -> Void

    init(service: any ProfileManaging, onSessionExpired: @escaping () -> Void) {
        self.service = service
        self.onSessionExpired = onSessionExpired
    }

    var isBusy: Bool { isSaving || isChangingPassword || isLinkingGoogle }

    func load() async {
        loadState = .loading
        switch await service.loadProfile() {
        case .success(let profile):
            show(profile)
            loadState = .loaded
        case .failure(.sessionExpired):
            onSessionExpired()
        case .failure(let failure):
            loadState = .failed(failure)
        }
    }

    func save() async {
        guard !isBusy else { return }
        attemptedSave = true
        isSaving = true
        defer { isSaving = false }
        switch await service.saveProfile(displayName: displayName, phone: phone) {
        case .saved(let profile):
            show(profile)
            profileValidation = ProfileValidation()
            profileBanner = Banner(status: .success, title: ProfileAnnouncements.saved, message: "Así queda tu cuenta.")
        case .unchanged:
            profileBanner = Banner(status: .warning, title: ProfileAnnouncements.unchanged, message: "Modifica tu nombre o tu celular.")
        case .invalid(let validation):
            profileValidation = validation
            profileBanner = Banner(
                status: .error, title: "Revisa los datos",
                message: ProfileAnnouncements.messages(for: validation).joined(separator: " ")
            )
        case .failed(.sessionExpired):
            onSessionExpired()
        case .failed(let failure):
            profileBanner = Banner(
                status: .error, title: "No se guardaron los cambios", message: ProfileAnnouncements.saveFailed(failure)
            )
        }
    }

    func changePassword() async {
        guard !isBusy else { return }
        attemptedPasswordChange = true
        isChangingPassword = true
        defer { isChangingPassword = false }
        switch await service.changePassword(current: currentPassword, new: newPassword, confirmation: confirmation) {
        case .changed:
            currentPassword = ""
            newPassword = ""
            confirmation = ""
            attemptedPasswordChange = false
            passwordValidation = PasswordChangeValidation()
            passwordBanner = Banner(
                status: .success, title: "Contraseña cambiada",
                message: "Se cerró tu sesión en los demás dispositivos."
            )
        case .invalid(let validation):
            passwordValidation = validation
            passwordBanner = Banner(
                status: .error, title: "Revisa la contraseña",
                message: ProfileAnnouncements.messages(for: validation).joined(separator: " ")
            )
        case .failed(.sessionExpired):
            onSessionExpired()
        case .failed(let failure):
            passwordBanner = Banner(
                status: .error, title: "No se cambió la contraseña",
                message: ProfileAnnouncements.passwordFailed(failure)
            )
        }
    }

    /// El audio lo da ProfileService; aquí solo el aviso en pantalla.
    func linkGoogle() async {
        guard !isBusy, !googleLinked else { return }
        isLinkingGoogle = true
        defer { isLinkingGoogle = false }
        switch await service.linkGoogle() {
        case .linked(let profile):
            googleLinked = profile.googleLinked
            googleBanner = Banner(status: .success, title: "Cuenta de Google asociada", message: GoogleSignInAnnouncements.linked)
        case .failed(.sessionExpired):
            onSessionExpired()
        case .failed(let failure):
            googleBanner = Banner(
                status: failure == .cancelled ? .warning : .error,
                title: GoogleSignInAnnouncements.title(for: failure, linking: true),
                message: GoogleSignInAnnouncements.message(for: failure)
            )
        }
    }

    private func show(_ profile: UserProfile) {
        googleLinked = profile.googleLinked
        email = profile.email
        displayName = profile.displayName ?? ""
        phone = profile.phone ?? ""
    }

    private func refreshProfileValidation() {
        guard attemptedSave else { return }
        profileValidation = ProfilePolicy.validate(displayName: displayName, phone: phone)
    }

    private func refreshPasswordValidation() {
        guard attemptedPasswordChange else { return }
        passwordValidation = PasswordChangePolicy.validate(
            current: currentPassword, new: newPassword, confirmation: confirmation
        )
    }
}
#endif
