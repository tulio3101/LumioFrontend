// El punto de entrada @main solo se compila para la app (target ejecutable de Xcode/xcodegen).
// En SwiftPM (el paso "Portable tests": `swift test`) se excluye: una librería con @main choca
// con el `_main` que genera el runner de XCTest ("duplicate symbol _main").
#if !SWIFT_PACKAGE
#if canImport(SwiftUI)
import SwiftUI

@main
@MainActor
struct LumioApp: App {
    private let dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            // SCRUM-33: la detección de obstáculos ya NO arranca por scenePhase/onAppear. Solo
            // corre mientras hay una ruta activa (la arranca y detiene DestinationViewModel).
            // Cuando la app pasa a background, ARKit pausa la entrega de frames por sí mismo
            // (sessionWasInterrupted) y la reanuda al volver si la ruta sigue activa, sin
            // destruir el pipeline. No hace falta tocar scenePhase aquí.
            #if os(iOS)
            RootView(
                sessionService: dependencies.sessionService,
                authenticationService: dependencies.authenticationService,
                routeCreator: dependencies.routeCreator,
                routeModifier: dependencies.routeModifier,
                instructionRepeater: dependencies.instructionRepeater,
                routeStatus: dependencies.routeStatus,
                recentRoutes: dependencies.recentRoutes,
                routeFinisher: dependencies.routeFinisher,
                arrivalMonitor: dependencies.arrivalMonitor,
                deviationMonitor: dependencies.deviationMonitor,
                destinationSuggester: dependencies.destinationSuggester,
                signOut: dependencies.signOut,
                profile: dependencies.profile,
                contacts: dependencies.contacts,
                emergency: dependencies.emergency,
                accountDeleter: dependencies.accountDeleter,
                voicePreferences: dependencies.voicePreferences,
                hapticPreferences: dependencies.hapticPreferences,
                permissions: dependencies.permissions,
                sessionExpiry: dependencies.sessionExpiry,
                safetyMonitor: dependencies.safetyService,
                obstacleGate: dependencies.obstacleGate,
                voiceCommands: dependencies.voiceCommands,
                homeStatus: dependencies.homeStatus,
                preferencesSync: dependencies.preferencesSync,
                narrationConsent: dependencies.narrationConsent,
                passwordRecovery: dependencies.passwordRecovery,
                environmentNarration: dependencies.environmentNarration,
                accessibilityPreferences: dependencies.accessibilityPreferences
            )
            // View.environmentObject() is iOS 13+; Scene.environmentObject() requires iOS 17.
            // Keeping this on the View avoids the availability constraint.
            #if DEBUG
            .environmentObject(DebugSafetyContainer(service: dependencies.safetyService))
            #endif
            #else
            RootView(
                sessionService: dependencies.sessionService,
                authenticationService: dependencies.authenticationService,
                routeCreator: dependencies.routeCreator,
                routeModifier: dependencies.routeModifier,
                instructionRepeater: dependencies.instructionRepeater,
                routeStatus: dependencies.routeStatus,
                recentRoutes: dependencies.recentRoutes,
                routeFinisher: dependencies.routeFinisher,
                arrivalMonitor: dependencies.arrivalMonitor,
                deviationMonitor: dependencies.deviationMonitor,
                destinationSuggester: dependencies.destinationSuggester,
                signOut: dependencies.signOut,
                profile: dependencies.profile,
                contacts: dependencies.contacts,
                emergency: dependencies.emergency,
                accountDeleter: dependencies.accountDeleter,
                voicePreferences: dependencies.voicePreferences,
                hapticPreferences: dependencies.hapticPreferences
            )
            #endif
        }
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
#endif
