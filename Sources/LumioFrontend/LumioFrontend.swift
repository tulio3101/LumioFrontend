#if canImport(SwiftUI)
import SwiftUI

@main
struct LumioApp: App {
    private let dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            RootView(navigationService: dependencies.navigationService)
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
