#if canImport(SwiftUI)
import SwiftUI

@main
@MainActor
struct LumioApp: App {
    private let dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            #if os(iOS)
            RootView(navigationService: dependencies.navigationService, permissions: dependencies.permissions)
            #else
            RootView(navigationService: dependencies.navigationService)
            #endif
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
