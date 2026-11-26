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
en el backend y anuncios por audio (prioridad 2). Modificar Ruta (SCRUM-9) cambia el
destino de la ruta activa sin crear otra; si no se puede, se mantiene la anterior y se
avisa por audio. En «Tu ruta», «Repetir indicación» (o el Magic Tap de VoiceOver)
vuelve a leer la indicación actual. Consultar Ruta Actual (SCRUM-23) dice por audio el
destino, el avance y la siguiente indicación con el Magic Tap de VoiceOver o «¿Cómo voy?»,
a partir de la copia local y del GPS, sin backend. Consultar Rutas Recientes (SCRUM-24)
lista los destinos de rutas anteriores (agrupados por lugar, del más reciente al más
antiguo) en su pantalla y en la hoja de destino; elegir uno calcula la ruta sin escribir.
Sin conexión se muestra la última lista guardada en el teléfono. Finalizar Ruta (SCRUM-10)
detiene las indicaciones, borra la copia local y lo anuncia por audio y háptica, a mano
(«Llegué a mi destino» o «Terminar sin llegar») o al detectar la llegada con el GPS,
también con el teléfono bloqueado (modo de fondo `location`). La ruta queda en el
historial del backend; sin red, se envía al volver la conexión. Recalcular Ruta (SCRUM-26)
detecta con el GPS que te saliste del trayecto (3 lecturas precisas a más de 30 m), lo
avisa por audio, calcula una ruta nueva al mismo destino y la anuncia; sin red sigue con
la copia local, lo avisa y recalcula al volver la conexión. También hay «Recalcular ruta»
a mano en «Tu ruta». El destino se escribe (con sugerencias) mientras no exista el dictado
(SCRUM-313). Guiar Giros durante el Trayecto (SCRUM-312) sigue el GPS durante la ruta activa
con la copia local (sin backend) y anuncia cada giro por audio (P2 del AudioArbiter) dos veces,
«En 40 metros, gira a la izquierda…» y «Ahora, gira…», con una vibración distinta para
izquierda y derecha; avisa antes de llegar y si se pierde la red o se degrada el GPS
(ver docs/HU-guiar-giros.md).
Configurar Contactos de Confianza (SCRUM-319) permite agregar, editar y eliminar los contactos
(nombre y correo, hasta 5) que recibirán por correo la alerta de emergencia, en Preferencias.
Se validan en el teléfono y en el backend, se guardan en `/contacts` y cada resultado se anuncia
por audio; el botón de emergencia que los usa es otra HU.
El Botón de Emergencia (SCRUM-35) está fijo en la parte inferior de Trayecto: al activarlo da
audio y háptica, deja 10 s para cancelar y luego envía por correo (vía el backend) la ubicación a los
contactos de confianza. Sin permiso de ubicación sale sin ella; sin contactos o sin conexión lo
informa por audio. No sustituye a los servicios de emergencia y así se lo dice al usuario.
El registro y el inicio de sesión con correo están conectados a /users: los tokens se
guardan en Keychain y se renuevan solos. «Continuar con Google» inicia sesión o crea la cuenta
con Google, y en Preferencias > Mi cuenta se puede asociar Google a una cuenta con contraseña;
la cancelación, la falta de red y los errores se dicen por audio (ver
docs/HU-iniciar-sesion-con-google.md).
En Iniciar sesión, «¿Olvidaste tu contraseña?» envía un código de 6 dígitos al correo y permite
crear una contraseña nueva sin revelar si la cuenta existe (ver docs/HU-recuperar-contrasena.md).
Audio ya incluye cola, política, árbitro y adaptador AVSpeechSynthesizer.
En Preferencias > Preferencias de voz se eligen el idioma (variante de español), la voz y la
velocidad de todo lo que dice Lumio; se guardan en el teléfono y se aplican desde la primera
locución al abrir la app (ver docs/HU-preferencias-de-voz.md).
En Preferencias > Vibración se activa o desactiva la vibración, se elige qué eventos de la ruta
vibran y con qué intensidad; las alertas de seguridad siempre vibran
(ver docs/HU-preferencias-hapticas.md).
También deduplica eventos P2/P3 y reemplaza narraciones pendientes de capturas
antiguas mediante metadatos opcionales; las reglas están en la guía de arquitectura.
No están implementados cámara, seguridad ni llamadas de narración.
El audio nativo está pendiente de validación en Xcode/dispositivo. No hay modelo Core ML ni claves de servicios incluidos.

## Configuración del backend (desarrollo)

`Resources/Info.plist` define `LumioAPIBaseURL` (por defecto `http://localhost:8000`;
en un iPhone físico usa la IP del equipo que corre el backend) y `GoogleClientID` (client ID
de Google de tipo iOS, el mismo que `GOOGLE_CLIENT_IDS` del backend; vacío deja Google sin
activar). Crea una cuenta desde la
app: las rutas se guardan con el access token de esa sesión. Sin sesión (solo DEBUG,
«Entrar sin sesión») o sin conexión, la ruta funciona igual pero queda pendiente de
guardarse en el servidor. «Mi cuenta», «Cerrar sesión» y «Eliminar cuenta» están en Preferencias.
En «Mi cuenta» (SCRUM-6) se consulta el correo y se cambian el nombre, el celular y la
contraseña; se valida en el teléfono y el resultado o el error se anuncian por audio.
Eliminar la cuenta (SCRUM-7) explica por audio qué se borra, pide dos confirmaciones y
llama a `DELETE /users/me`; solo si el backend confirma, borra del teléfono la ruta, las
rutas recientes, el historial pendiente y la sesión. Sin conexión no se elimina nada.

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
    Narration/             Consentimiento (SCRUM-324) y Narración del Entorno (SCRUM-38)
    Users/                 Sesión (Keychain, Bearer, refresh), registro/login, perfil, cerrar sesión y eliminar cuenta
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
