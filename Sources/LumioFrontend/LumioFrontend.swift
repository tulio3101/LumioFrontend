#if canImport(SwiftUI)
import SwiftUI

@main
@MainActor
struct LumioApp: App {
    private let dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            RootView(
                sessionService: dependencies.sessionService,
                authenticationService: dependencies.authenticationService,
                routeCreator: dependencies.routeCreator,
                routeModifier: dependencies.routeModifier,
                instructionRepeater: dependencies.instructionRepeater,
                routeStatus: dependencies.routeStatus,
                destinationSuggester: dependencies.destinationSuggester,
                signOut: dependencies.signOut
            )
        }
    }
}
#else
// Linux permite comprobar los contratos; la aplicación iOS se ejecuta con Xcode.
@main
struct LumioFrontend {
    static func main() {
        print("Lumio: abre el proyecto generado con Xcode para ejecutar la app iOS.")
    }
}
#endif
