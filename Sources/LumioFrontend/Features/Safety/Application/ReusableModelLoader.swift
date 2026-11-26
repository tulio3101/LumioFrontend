import Foundation

/// SCRUM-314: el modelo de detección se carga una sola vez y se reutiliza en cada ruta.
/// `warmUp()` lo carga en segundo plano al abrir la app, así la primera ruta no espera a
/// Core ML; si la ruta empieza antes de que termine, `load()` espera a esa misma carga en
/// lugar de abrir otra. Nunca corre en el hilo principal: lo llaman el pipeline (tarea
/// desacoplada) o la precarga.
///
/// Si la carga falla no se guarda nada y el siguiente `load()` lo intenta de nuevo. Cuando
/// `RecoveringModel` reconstruye el modelo tras un fallo de inferencia llama a
/// `discard()` primero: el modelo que falló no se vuelve a entregar.
final class ReusableModelLoader<Model>: @unchecked Sendable {
    private let factory: () throws -> Model
    private let lock = NSLock()
    private var model: Model?
    private(set) var loadCount = 0

    init(factory: @escaping () throws -> Model) {
        self.factory = factory
    }

    /// El modelo ya cargado o, si no hay, una carga nueva. Las llamadas simultáneas esperan
    /// a la primera y reciben el mismo modelo.
    func load() throws -> Model {
        lock.lock()
        defer { lock.unlock() }
        if let model { return model }
        loadCount += 1
        let loaded = try factory()
        model = loaded
        return loaded
    }

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return model != nil
    }

    /// Olvida el modelo para que la próxima carga sea nueva.
    func discard() {
        lock.lock()
        model = nil
        lock.unlock()
    }

    /// Precarga en segundo plano. Un fallo no se informa aquí: lo publica el pipeline al
    /// iniciar la ruta, con sus reintentos y su aviso por audio.
    func warmUp(priority: TaskPriority = .utility) {
        Task.detached(priority: priority) { [self] in
            _ = try? self.load()
        }
    }
}
