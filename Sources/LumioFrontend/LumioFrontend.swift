#if canImport(SwiftUI)
import SwiftUI
import OSLog

@main
@MainActor
struct LumioApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let dependencies = AppDependencies()
    private let logger = Logger(subsystem: "com.lumio.app", category: "LumioApp")

    var body: some Scene {
        WindowGroup {
            RootView(navigationService: dependencies.navigationService)
                .onAppear {
                    // onChange(of: scenePhase) misses the first .active because the scene is
                    // already active when the view is built. Fire it manually here instead.
                    #if os(iOS)
                    handleScenePhase(.active)
                    #endif
                }
                // View.environmentObject() is iOS 13+; Scene.environmentObject() requires iOS 17.
                // Keeping this on the View avoids the availability constraint.
                #if os(iOS) && DEBUG
                .environmentObject(DebugSafetyContainer(service: dependencies.safetyService))
                #endif
        }
        // Handles subsequent foreground/background transitions after the first launch.
        .onChange(of: scenePhase) { newPhase in
            handleScenePhase(newPhase)
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        #if os(iOS)
        logger.debug("scenePhase → \(String(describing: phase))")
        switch phase {
        case .active:
            // TODO: guard user is authenticated before starting camera — no auth system
            // exists yet in the app; add the check here when a login flow is added.
            // TODO: move start()/stop() calls to MapKitNavigationService.startSession() /
            // endSession() when explicit navigation sessions are introduced (SCRUM-33 follow-up).
            guard let safety = dependencies.safetyService else {
                logger.warning("safetyService es nil — ¿está yolo26n_640_int8.mlpackage en Compile Sources y xcodegen regenerado?")
                #if canImport(AVFoundation)
                dependencies.audioArbiter.receive(AudioMessage(
                    text: "La detección de obstáculos no está disponible.",
                    priority: .immediateRisk,
                    deduplicationKey: "safety-start-failed"
                ))
                #endif
                return
            }
            logger.info("Iniciando SafetyService")
            Task {
                do {
                    try await safety.start()
                } catch {
                    logger.error("SafetyService.start() falló: \(error)")
                    #if canImport(AVFoundation)
                    dependencies.audioArbiter.receive(AudioMessage(
                        text: "La detección de obstáculos no está disponible.",
                        priority: .immediateRisk,
                        deduplicationKey: "safety-start-failed"
                    ))
                    #endif
                }
            }
        case .background:
            // Do NOT call stop() here. stop() calls continuation.finish() on the internal
            // AsyncStream, permanently terminating it — the pipeline cannot recover without
            // recreating the full object graph. ARKit already handles background interruptions
            // natively: sessionWasInterrupted pauses frame delivery and sessionInterruptionEnded
            // resumes it automatically when the app returns to foreground.
            // TODO: call safetyService?.stop() from MapKitNavigationService.endSession()
            // when explicit navigation sessions are introduced.
            logger.info("App a background — ARKit gestiona la interrupción automáticamente")
        default:
            break
        }
        #endif
    }
}
#else
// Linux allows contract checks; the iOS app runs via Xcode.
@main
struct LumioFrontend {
    static func main() {
        print("Lumio: abre el proyecto generado con Xcode para ejecutar la app iOS.")
    }
}
#endif
