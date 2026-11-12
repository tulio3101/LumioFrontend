#if os(iOS)
import AVFoundation
import CoreLocation
import Speech
import UserNotifications

@MainActor
final class IOSPermissionProvider: NSObject, PermissionProviding, CLLocationManagerDelegate {
    private let location = CLLocationManager()
    private var locationRequest: CheckedContinuation<PermissionStatus, Never>?

    override init() {
        super.init()
        location.delegate = self
    }

    func status(for permission: AppPermission) async -> PermissionStatus {
        switch permission {
        case .camera:
            guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
            return captureStatus(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: return .authorized
            case .denied: return .denied
            case .undetermined: return .notDetermined
            @unknown default: return .unavailable
            }
        case .speechRecognition:
            return speechStatus(SFSpeechRecognizer.authorizationStatus())
        case .location:
            guard CLLocationManager.locationServicesEnabled() else { return .unavailable }
            return locationStatus(location.authorizationStatus)
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .authorized
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .unavailable
            }
        }
    }

    func request(_ permission: AppPermission) async throws -> PermissionStatus {
        // Defensa adicional: nunca intentar reabrir un diálogo ya resuelto.
        let current = await status(for: permission)
        guard current == .notDetermined else { return current }
        switch permission {
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        case .speechRecognition:
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        case .location:
            return await withCheckedContinuation { continuation in
                locationRequest = continuation
                location.requestWhenInUseAuthorization()
            }
        case .notifications:
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        return await status(for: permission)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let state = self.locationStatus(self.location.authorizationStatus)
            guard state != .notDetermined, let continuation = self.locationRequest else { return }
            self.locationRequest = nil
            continuation.resume(returning: state)
        }
    }

    private func captureStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unavailable
        }
    }

    private func speechStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unavailable
        }
    }

    private func locationStatus(_ status: CLAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unavailable
        }
    }
}
#endif
