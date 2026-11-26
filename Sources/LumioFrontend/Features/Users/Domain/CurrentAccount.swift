import Foundation

/// Identidad de la cuenta en uso para decidir de quién son las rutas finalizadas pendientes
/// (SCRUM-360). `currentAccountID` se fija al iniciar sesión y se usa como clave de propietario.
/// `pendingOwnerAccountID` marca a qué cuenta pertenece lo pendiente cuando esa cuenta se va, para
/// no subirlo con otra y reenviarlo si vuelve el mismo usuario.
protocol CurrentAccountStoring: AnyObject {
    var currentAccountID: String? { get set }
    var pendingOwnerAccountID: String? { get set }
}

/// Persistencia ligera en UserDefaults (solo identificadores de cuenta, nunca tokens ni datos).
final class UserDefaultsCurrentAccount: CurrentAccountStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let currentKey = "lumio.currentAccountID"
    private let pendingOwnerKey = "lumio.pendingOwnerAccountID"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var currentAccountID: String? {
        get { defaults.string(forKey: currentKey) }
        set { defaults.set(newValue, forKey: currentKey) }
    }

    var pendingOwnerAccountID: String? {
        get { defaults.string(forKey: pendingOwnerKey) }
        set { defaults.set(newValue, forKey: pendingOwnerKey) }
    }
}
