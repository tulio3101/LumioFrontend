import Foundation

/// DELETE /users/me: borra la cuenta en el backend con la sesión actual.
protocol AccountRemoving {
    func deleteAccount() async throws
}

/// Eliminar Cuenta (SCRUM-7). La pantalla pide dos confirmaciones, cada una explicada por
/// audio, y solo entonces llama a `deleteAccount()`. Todo el audio pasa por el AudioArbiter.
@MainActor
protocol AccountDeleting: AnyObject {
    /// Primera confirmación: locuta qué se borra y que no se puede deshacer.
    func explainConsequences()
    /// Segunda y última confirmación, justo antes de borrar.
    func askForFinalConfirmation()
    /// Deja de locutar las confirmaciones (el usuario canceló).
    func cancel()
    /// nil si ya hay una eliminación en curso (doble toque).
    func deleteAccount() async -> AccountDeletionOutcome?
}

/// Resultado de eliminar la cuenta. Salvo `.deleted`, la cuenta sigue intacta.
enum AccountDeletionOutcome: Equatable {
    /// El backend la borró y el teléfono ya no guarda nada de ella.
    case deleted
    /// Sin conexión: no llegó al backend.
    case offline
    /// La sesión ya no vale (refresh rechazado): hay que volver a iniciar sesión.
    case sessionExpired
    /// El backend no pudo borrarla (500/503) o no está configurado.
    case failed

    /// Sin cuenta o sin sesión en el teléfono: la app vuelve a la bienvenida.
    var leavesTheApp: Bool { self == .deleted || self == .sessionExpired }
}

/// Textos de la pantalla y del audio: lo que se ve es lo mismo que se oye.
enum AccountDeletionAnnouncements {
    static let title = "Eliminar cuenta"

    static let consequences = [
        "Tu cuenta y tu correo dejan de funcionar en Lumio: no podrás volver a iniciar sesión con ella.",
        "Se borran tus contactos de confianza, tu historial de rutas y tus preferencias.",
        "Se detiene la ruta en curso y se borra lo que la cuenta guarda en este teléfono.",
        "No se puede deshacer. Si vuelves, tendrás que crear una cuenta nueva.",
    ]

    static let explanation = "Vas a eliminar tu cuenta de Lumio. "
        + consequences.joined(separator: " ")
        + " Para continuar, activa Eliminar mi cuenta. Para salir, activa Cancelar."

    static let finalQuestion = "¿Eliminar tu cuenta para siempre?"
    static let finalMessage = "Es la última confirmación. Se borran tu cuenta, tus contactos de confianza, "
        + "tu historial de rutas y tus preferencias. No se puede deshacer."
    static let finalConfirmation = finalQuestion + " " + finalMessage
        + " Activa Eliminar definitivamente o Cancelar."

    static let deleting = "Eliminando tu cuenta."

    static func title(for outcome: AccountDeletionOutcome) -> String {
        switch outcome {
        case .deleted: "Cuenta eliminada"
        case .offline: "Sin conexión"
        case .sessionExpired: "Sesión expirada"
        case .failed: "No se pudo eliminar la cuenta"
        }
    }

    static func message(for outcome: AccountDeletionOutcome) -> String {
        switch outcome {
        case .deleted:
            "Tu cuenta y sus datos fueron eliminados. Ya no podrás iniciar sesión con ella."
        case .offline:
            "No se pudo eliminar la cuenta. Tu cuenta sigue activa. Intenta de nuevo cuando tengas conexión."
        case .sessionExpired:
            "Tu cuenta sigue activa. Inicia sesión de nuevo para eliminarla."
        case .failed:
            "No se pudo eliminar la cuenta. Tu cuenta sigue activa. Intenta de nuevo más tarde."
        }
    }

    /// Lo que se locuta: título y mensaje.
    static func spoken(for outcome: AccountDeletionOutcome) -> String {
        "\(title(for: outcome)). \(message(for: outcome))"
    }
}
