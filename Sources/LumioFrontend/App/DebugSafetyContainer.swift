#if os(iOS) && DEBUG
import Foundation

/// Ferries the optional SafetyService into the SwiftUI environment for debug views.
/// Injected in LumioApp and consumed via @EnvironmentObject in DestinationView.
final class DebugSafetyContainer: ObservableObject {
    let service: SafetyService?
    init(service: SafetyService?) { self.service = service }
}
#endif
