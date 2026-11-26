import Foundation
import Testing
@testable import LumioFrontend

// SCRUM-314: Preparar la Cámara y la Seguridad al Iniciar el Trayecto.

private final class CountingFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var failures = 0

    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }

    func make() throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if failures > 0 {
            failures -= 1
            throw DetectionModelError.modelLoadingFailed
        }
        return UUID()
    }
}

@Test func modelIsLoadedOnceAndReused() throws {
    let factory = CountingFactory()
    let loader = ReusableModelLoader { try factory.make() }
    let first = try loader.load()
    let second = try loader.load()
    #expect(first == second)
    #expect(factory.count == 1)
    #expect(loader.isLoaded)
}

@Test func concurrentLoadsShareTheSameModel() async throws {
    let factory = CountingFactory()
    let loader = ReusableModelLoader { try factory.make() }
    let models = await withTaskGroup(of: UUID?.self) { group in
        for _ in 0..<8 { group.addTask { try? loader.load() } }
        var all: [UUID?] = []
        for await model in group { all.append(model) }
        return all
    }
    #expect(Set(models.compactMap { $0 }).count == 1)
    #expect(factory.count == 1)
}

@Test func failedLoadIsRetriedOnTheNextRequest() throws {
    let factory = CountingFactory()
    factory.failures = 1
    let loader = ReusableModelLoader { try factory.make() }
    #expect(throws: DetectionModelError.modelLoadingFailed) { try loader.load() }
    #expect(!loader.isLoaded)
    _ = try loader.load()
    #expect(factory.count == 2)
}

@Test func discardedModelIsReplacedByAFreshOne() throws {
    let factory = CountingFactory()
    let loader = ReusableModelLoader { try factory.make() }
    let old = try loader.load()
    loader.discard()
    #expect(try loader.load() != old)
    #expect(factory.count == 2)
}

@Test func warmUpLoadsInTheBackground() async throws {
    let factory = CountingFactory()
    let loader = ReusableModelLoader { try factory.make() }
    loader.warmUp()
    for _ in 0..<200 where !loader.isLoaded {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(loader.isLoaded)
    // La ruta reutiliza lo precargado.
    _ = try loader.load()
    #expect(factory.count == 1)
}

@Test func recoveryDiscardsTheSharedModelBeforeRebuilding() async {
    let factory = CountingFactory()
    let loader = ReusableModelLoader { try factory.make() }
    var failNext = true
    let model = RecoveringModel<Int, Int>(
        factory: {
            _ = try loader.load()
            return { value in
                if failNext {
                    failNext = false
                    throw DetectionModelError.inferenceFailed
                }
                return value
            }
        },
        policy: ModelRecoveryPolicy(delays: [0]),
        sleep: { _ in },
        report: { _ in },
        discard: { loader.discard() }
    )
    #expect(await model.prepare())
    #expect(await model.process(1) == nil)
    // La reconstrucción cargó un modelo nuevo, no el que falló.
    #expect(factory.count == 2)
    #expect(await model.process(2) == 2)
}

@Test(arguments: [true, false])
func cameraReadyIsSpokenAsRouteInformation(fullMode: Bool) {
    let now = Date(timeIntervalSince1970: 100)
    let message = fullMode ? SafetyAudio.fullMode(now: now) : SafetyAudio.reducedMode(now: now)
    #expect(message.text.hasPrefix("Cámara lista."))
    #expect(message.text.contains(fullMode ? "Modo completo" : "Modo reducido"))
    // Se tiene que oír (P2), pero una alerta P1 lo interrumpe y tarde ya no sirve.
    #expect(message.priority == .routeInformation)
    #expect(message.expiresAt == now.addingTimeInterval(15))
    #expect(message.contextID == SafetyAudio.context)
}

@Test func cameraReadyAlwaysVibrates() {
    #expect(HapticCue.alwaysOn.contains(.safetyReady))
    #expect(!HapticCue.configurable.contains(.safetyReady))
    let pattern = HapticPattern.pattern(for: .safetyReady, intensity: .soft)
    #expect(pattern.pulses.count == 2)
    #expect(HapticPreferences(isEnabled: false, intensity: .soft, disabledCues: []).plays(.safetyReady))
}
