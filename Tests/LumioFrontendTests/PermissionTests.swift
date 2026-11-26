import Foundation
import Testing
@testable import LumioFrontend

@MainActor
private final class FakePermissionProvider: PermissionProviding {
    var values: [AppPermission: PermissionStatus] = [:]
    var requested: [AppPermission] = []
    var response: PermissionStatus = .authorized
    func status(for permission: AppPermission) async -> PermissionStatus {
        values[permission] ?? .notDetermined
    }
    func request(_ permission: AppPermission) async throws -> PermissionStatus {
        requested.append(permission)
        values[permission] = response
        return response
    }
}

@Test @MainActor func deniedAndRestrictedPermissionsDoNotPromptAgain() async throws {
    let provider = FakePermissionProvider()
    let service = PermissionService(provider: provider)
    for state in [PermissionStatus.denied, .restricted, .unavailable, .authorized] {
        provider.values[.microphone] = state
        let result = try await service.request(.microphone)
        #expect(result == state)
    }
    #expect(provider.requested.isEmpty)
}

@Test @MainActor func undeterminedPermissionUsesSystemResult() async throws {
    let provider = FakePermissionProvider()
    provider.response = .denied
    let service = PermissionService(provider: provider)
    let first = try await service.request(.microphone)
    let second = try await service.request(.microphone)
    #expect(first == .denied)
    #expect(second == .denied)
    #expect(provider.requested == [.microphone])
}

@Test @MainActor func voiceRequiresBothPermissionsButRouteCalculationOnlyLocation() async {
    let provider = FakePermissionProvider()
    let service = PermissionService(provider: provider)
    let voice = await service.missing(for: .voiceDestination)
    let route = await service.missing(for: .route)
    let obstacles = await service.missing(for: .obstacleAssistance)
    #expect(voice == [.microphone, .speechRecognition])
    #expect(route == [.location])
    #expect(obstacles == [.camera])
    provider.values[.microphone] = .authorized
    let remaining = await service.missing(for: .voiceDestination)
    #expect(remaining == [.speechRecognition])
}

@Test @MainActor func authorizationIsRecheckedAfterSettingsAndRevocation() async {
    let provider = FakePermissionProvider()
    let service = PermissionService(provider: provider)
    provider.values[.location] = .authorized
    let ready = await service.missing(for: .route)
    #expect(ready.isEmpty)
    provider.values[.location] = .denied
    let revoked = await service.missing(for: .route)
    #expect(revoked == [.location])
    provider.values[.location] = .authorized
    let restored = await service.statuses()
    #expect(restored[.location] == .authorized)
    #expect(provider.requested.isEmpty)
}

@MainActor
private final class WaitingAudioPlayer: AudioPlaying {
    var onFinished: ((PlaybackToken) -> Void)?
    var onStarted: (() -> Void)?
    var token: PlaybackToken?
    func play(_ message: AudioMessage, token: PlaybackToken) throws {
        self.token = token
        onStarted?()
    }
    func stop() { token = nil }
    func finish() {
        guard let token else { return }
        self.token = nil
        onFinished?(token)
    }
}

@Test @MainActor func explanationWaitsForActualPlaybackCompletion() async {
    let player = WaitingAudioPlayer()
    let arbiter = AudioArbiterService(player: player)
    var waiting: Task<Bool, Never>?
    await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
        player.onStarted = { started.resume() }
        waiting = Task {
            await arbiter.receiveAndWait(AudioMessage(text: "Permiso", priority: .routeInformation))
        }
    }
    player.onStarted = nil
    #expect(arbiter.currentMessage?.text == "Permiso")
    player.finish()
    let finished = await waiting!.value
    #expect(finished)
    #expect(arbiter.currentMessage == nil)
}

@Test @MainActor func cancellingExplanationReleasesAudioAndWaiter() async {
    let player = WaitingAudioPlayer()
    let arbiter = AudioArbiterService(player: player)
    var waiting: Task<Bool, Never>?
    await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
        player.onStarted = { started.resume() }
        waiting = Task {
            await arbiter.receiveAndWait(AudioMessage(text: "Permiso", priority: .routeInformation))
        }
    }
    player.onStarted = nil
    waiting!.cancel()
    let finished = await waiting!.value
    #expect(!finished)
    #expect(arbiter.currentMessage == nil)
    #expect(arbiter.pendingMessages.isEmpty)
}

@Test @MainActor func safetyInterruptsExplanationAndExplanationResumes() async {
    let player = WaitingAudioPlayer()
    let arbiter = AudioArbiterService(player: player)
    var waiting: Task<Bool, Never>?
    await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
        player.onStarted = { started.resume() }
        waiting = Task {
            await arbiter.receiveAndWait(AudioMessage(text: "Permiso", priority: .routeInformation))
        }
    }
    player.onStarted = nil
    arbiter.receive(AudioMessage(text: "Obstáculo", priority: .immediateRisk))
    #expect(arbiter.currentMessage?.text == "Obstáculo")
    player.finish()
    #expect(arbiter.currentMessage?.text == "Permiso")
    player.finish()
    let finished = await waiting!.value
    #expect(finished)
}
