# Lumio iOS

Cliente nativo SwiftUI de Lumio. La app ejecuta seguridad, navegación y arbitraje
de audio localmente. FastAPI aporta usuarios y generación de narración.

## Arranque

En macOS con Xcode y XcodeGen instalados:

```sh
xcodegen generate --spec project.yml
open lumio.xcodeproj
```

Selecciona el scheme `lumio` y un simulador iPhone. Ejecuta con Run; usa Test para
las pruebas. Para un dispositivo configura tu equipo de firma en Xcode.
El proyecto generado no es la fuente de configuración: modifica `project.yml`.

Con Swift 6.0 o posterior, incluidos Linux y macOS:

```sh
swift test
```

SwiftPM comprueba contratos, modelos y código portable. En Linux **no** compila
SwiftUI, AVFoundation ni MapKit. La validación de la aplicación se hace con Xcode.
La app conserva iOS 16 como mínimo y modo de lenguaje Swift 5 tanto en SwiftPM
como en XcodeGen. La versión de herramientas y el modo de lenguaje son distintos.

## Estado actual

Hay una app SwiftUI con destino y preferencias, contratos por funcionalidad,
transporte HTTP y DTOs de narración. Crear Ruta (SCRUM-8) está conectada: ubicación
con CoreLocation, destino y ruta a pie con MapKit, copia local en disco, persistencia
en el backend y anuncios por audio (prioridad 2). El destino se escribe mientras no
exista el dictado (SCRUM-313); la guía de giros durante el trayecto es SCRUM-312.
Audio ya incluye cola, política, árbitro y adaptador AVSpeechSynthesizer.
También deduplica eventos P2/P3 y reemplaza narraciones pendientes de capturas
antiguas mediante metadatos opcionales; las reglas están en la guía de arquitectura.
No están implementados cámara, seguridad, autenticación ni llamadas de narración.
El audio nativo está pendiente de validación en Xcode/dispositivo. No hay modelo Core ML ni claves de servicios incluidos.

## Configuración del backend (desarrollo)

`Resources/Info.plist` define `LumioAPIBaseURL` (por defecto `http://localhost:8000`;
en un iPhone físico usa la IP del Mac) y `LumioDevUserID`, el UUID que imprime
`python -m app.scripts.seed_dev_user` en el backend. Es provisional hasta el login:
sin él la ruta funciona igual, pero queda pendiente de guardarse en el servidor.

## Organización

```text
Sources/LumioFrontend/
  LumioFrontend.swift       Entrada @main (SwiftUI en Apple)
  App/                     Composición de dependencias y navegación raíz
  Core/                    Transporte HTTP y errores compartidos
  Shared/UI/               Componentes visuales reutilizables y tokens de color
  Resources/               Recursos del target (declarados en Package.swift)
  Features/
    Navigation/            Domain, Data, Presentation: ejemplo completo de capas
    Safety/Domain/         Eventos y contrato de monitor local
    Audio/                 Domain, Application (árbitro), Data (reproductor nativo)
    Narration/             Contrato local y DTOs del backend
    Users/                 Perfil, sesión y formularios de registro/login (sin backend)
    Welcome/Presentation/  Bienvenida sin sesión activa
    Places/Domain/         Lugares guardados y contrato de carga
    Settings/Presentation/ Preferencias (pantalla inicial)
Tests/LumioFrontendTests/
docs/ARCHITECTURE.md
```

Lee [la guía de arquitectura y equivalencias con React](docs/ARCHITECTURE.md)
antes de agregar una funcionalidad. Se agrupa por funcionalidad y se componen las
vistas: no son alternativas incompatibles.

ab
