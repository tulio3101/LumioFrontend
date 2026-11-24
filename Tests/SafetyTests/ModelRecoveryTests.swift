import Foundation
import Testing
@testable import LumioFrontend

private final class ModelScript: @unchecked Sendable {
    private let lock = NSLock()
    private var loads: [DetectionModelError?]
    private var inferences: [DetectionModelError?]
    private var numberOfLoads = 0
    var emptyOutput = false

    init(loads: [DetectionModelError?] = [], inferences: [DetectionModelError?] = []) {
        self.loads = loads
        self.inferences = inferences
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return numberOfLoads
    }

    func make() throws -> (Int) throws -> [Int] {
        lock.lock()
        numberOfLoads += 1
        let failure = loads.isEmpty ? nil : loads.removeFirst()
        lock.unlock()
        if let failure { throw failure }
        return { input in
            self.lock.lock()
            let failure = self.inferences.isEmpty ? nil : self.inferences.removeFirst()
            self.lock.unlock()
            if let failure { throw failure }
            return self.emptyOutput ? [] : [input]
        }
    }
}

private actor RecoveryLog {
    var statuses: [SafetyStatus] = []
    var delays: [UInt64] = []
    func status(_ value: SafetyStatus) { statuses.append(value) }
    func delay(_ value: UInt64) { delays.append(value) }
}

private func model(_ script: ModelScript, _ log: RecoveryLog) -> RecoveringModel<Int, [Int]> {
    RecoveringModel(factory: { try script.make() }, policy: ModelRecoveryPolicy(delays: [1, 2, 4]),
                    sleep: { await log.delay($0) }, report: { await log.status($0) })
}

@Test func missingModelIsReportedWithoutPointlessReloads() async {
    let script = ModelScript(loads: [.modelNotFound])
    let log = RecoveryLog()
    let detector = model(script, log)
    let prepared = await detector.prepare()
    let states = await log.statuses
    let delays = await log.delays
    #expect(!prepared)
    #expect(script.loadCount == 1)
    #expect(delays.isEmpty)
    #expect(states == [.starting, .unavailable(.model(.modelNotFound))])
}

@Test func transientLoadFailuresRecoverButWaitForInferenceBeforeReportingRunning() async {
    let script = ModelScript(loads: [.modelLoadingFailed, .modelLoadingFailed, nil])
    let log = RecoveryLog()
    let detector = model(script, log)
    let prepared = await detector.prepare()
    let beforeFrame = await detector.status
    #expect(prepared)
    #expect(beforeFrame == .recovering(attempt: 2))
    let output = await detector.process(7)
    let afterFrame = await detector.status
    let delays = await log.delays
    #expect(output == [7])
    #expect(afterFrame == .running)
    #expect(delays == [1, 2])
}

@Test func continuousInferenceFailuresExhaustTheSharedBudget() async {
    let script = ModelScript(inferences: Array(repeating: .inferenceFailed, count: 4))
    let log = RecoveryLog()
    let detector = model(script, log)
    _ = await detector.prepare()
    for value in 1...4 {
        let output = await detector.process(value)
        #expect(output == nil)
    }
    let states = await log.statuses
    let delays = await log.delays
    #expect(script.loadCount == 4) // carga inicial + tres reconstrucciones
    #expect(delays == [1, 2, 4])
    #expect(states.last == .unavailable(.model(.inferenceFailed)))
}

@Test func incompatibleResultsAreFailuresInsteadOfEmptyScenes() async {
    let script = ModelScript(inferences: [.invalidOutput])
    let log = RecoveryLog()
    let detector = model(script, log)
    _ = await detector.prepare()
    let output = await detector.process(1)
    let status = await detector.status
    #expect(output == nil)
    #expect(status == .unavailable(.model(.invalidOutput)))
    #expect(script.loadCount == 1)
}

@Test func emptyValidSceneIsHealthy() async {
    let script = ModelScript()
    script.emptyOutput = true
    let detector = model(script, RecoveryLog())
    _ = await detector.prepare()
    let output = await detector.process(1)
    let status = await detector.status
    #expect(output == [])
    #expect(status == .running)
}

@Test func recoveryDropsTheFailedFrameAndProcessesAFreshOne() async {
    let script = ModelScript(inferences: [.inferenceFailed, nil])
    let log = RecoveryLog()
    let detector = model(script, log)
    _ = await detector.prepare()
    let stale = await detector.process(1)
    let fresh = await detector.process(2)
    let states = await log.statuses
    #expect(stale == nil)
    #expect(fresh == [2])
    #expect(states == [.starting, .recovering(attempt: 1), .running])
}

@Test func successfulInferenceResetsTheIncidentBudget() async {
    let script = ModelScript(inferences: [.inferenceFailed, nil, .inferenceFailed])
    let log = RecoveryLog()
    let detector = model(script, log)
    _ = await detector.prepare()
    _ = await detector.process(1)
    _ = await detector.process(2)
    _ = await detector.process(3)
    let delays = await log.delays
    #expect(delays == [1, 1])
}

@Test func cancellationDuringBackoffDoesNotReloadOrReportRecovery() async {
    let script = ModelScript(loads: [.modelLoadingFailed])
    let log = RecoveryLog()
    let waiting = makeSafetyStream(of: Bool.self)
    let detector = RecoveringModel<Int, [Int]>(factory: { try script.make() },
        sleep: { _ in
            waiting.continuation.yield(true)
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }, report: { await log.status($0) })
    let task = Task { await detector.prepare() }
    var iterator = waiting.stream.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()
    let prepared = await task.value
    waiting.continuation.finish()
    let states = await log.statuses
    #expect(!prepared)
    #expect(script.loadCount == 1)
    #expect(!states.contains(.running))
}

@Test func loadAndInferenceFailuresShareOneBudget() async {
    let script = ModelScript(loads: [.modelLoadingFailed, nil],
                             inferences: [.inferenceFailed, .inferenceFailed, .inferenceFailed])
    let log = RecoveryLog()
    let detector = model(script, log)
    _ = await detector.prepare()
    for value in 1...3 { _ = await detector.process(value) }
    let state = await detector.status
    let delays = await log.delays
    #expect(delays == [1, 2, 4])
    #expect(script.loadCount == 4)
    #expect(state == .unavailable(.model(.inferenceFailed)))
}
