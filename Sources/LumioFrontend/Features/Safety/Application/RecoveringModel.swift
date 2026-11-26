import Foundation

/// Modelo y operación viven en un único actor, fuera del hilo principal.
/// La fábrica y el reloj se inyectan para probar errores sin Core ML ni cámara.
actor RecoveringModel<Input, Output> {
    typealias Operation = (Input) throws -> Output
    private let factory: () throws -> Operation
    private let policy: ModelRecoveryPolicy
    private let sleep: (UInt64) async throws -> Void
    private let report: (SafetyStatus) async -> Void
    /// SCRUM-314: olvida un modelo compartido antes de reconstruirlo (ReusableModelLoader).
    private let discard: () -> Void
    private var operation: Operation?
    private var attempts = 0
    private(set) var status = SafetyStatus.stopped

    init(
        factory: @escaping () throws -> Operation,
        policy: ModelRecoveryPolicy = ModelRecoveryPolicy(),
        sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        report: @escaping (SafetyStatus) async -> Void,
        discard: @escaping () -> Void = {}
    ) {
        self.factory = factory
        self.policy = policy
        self.sleep = sleep
        self.report = report
        self.discard = discard
    }

    func prepare() async -> Bool {
        guard !Task.isCancelled else { return false }
        await transition(.starting)
        do {
            operation = try factory()
            return !Task.isCancelled
        } catch is CancellationError {
            return false
        } catch {
            return await recover(after: classify(error, loading: true))
        }
    }

    func process(_ input: Input) async -> Output? {
        guard !Task.isCancelled, operation != nil else { return nil }
        do {
            let output = try infer(input)
            guard !Task.isCancelled else { return nil }
            attempts = 0
            // Solo una inferencia válida confirma recuperación, incluso si no hay objetos.
            await transition(.running)
            return output
        } catch is CancellationError {
            return nil
        } catch {
            _ = await recover(after: classify(error, loading: false))
            // Nunca reinferir ni publicar el frame viejo después de la espera.
            return nil
        }
    }

    /// El préstamo de la operación termina antes de reconstruir el modelo en el catch.
    private func infer(_ input: Input) throws -> Output {
        guard let operation else { throw DetectionModelError.inferenceFailed }
        return try operation(input)
    }

    private func recover(after initial: DetectionModelError) async -> Bool {
        operation = nil
        // El modelo que falló no se reutiliza: la reconstrucción carga uno nuevo.
        discard()
        var failure = initial
        while !Task.isCancelled {
            guard failure.canRetry, attempts < policy.delays.count else {
                await transition(.unavailable(.model(failure)))
                return false
            }
            let delay = policy.delays[attempts]
            attempts += 1
            await transition(.recovering(attempt: attempts))
            do {
                try await sleep(delay)
                try Task.checkCancellation()
                operation = try factory()
                return true
            } catch is CancellationError {
                return false
            } catch {
                failure = classify(error, loading: true)
            }
        }
        return false
    }

    private func classify(_ error: Error, loading: Bool) -> DetectionModelError {
        (error as? DetectionModelError) ?? (loading ? .modelLoadingFailed : .inferenceFailed)
    }

    private func transition(_ next: SafetyStatus) async {
        guard status != next, !Task.isCancelled else { return }
        status = next
        await report(next)
    }
}
