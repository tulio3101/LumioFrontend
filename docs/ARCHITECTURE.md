# Guía para desarrollar Lumio

## Estructura elegida

Modular por funcionalidad, con vistas SwiftUI por componentes y separación MVVM
ligera. Por ahora las carpetas NO son módulos binarios independientes: todo
pertenece al target LumioFrontend. Separar targets solo cuando haya una necesidad
real de aislamiento o reutilización. No hace falta agregar las tres capas a una
funcionalidad que aún no las necesita.

- Domain: modelos de la funcionalidad y protocolos. Sin vistas ni llamadas HTTP.
- Data: adaptadores concretos (MapKit, backend, almacenamiento) y DTOs externos.
- Presentation: View y ViewModel; presenta estado y recibe acciones del usuario.
- App: conecta implementaciones e interfaces. Evitar singletons globales.
- Shared/UI: solo vistas que varias funcionalidades realmente reutilizan.
- Core: infraestructura técnica común; no convertirlo en un cajón de negocio.

Swift no exige un archivo por clase. Preferimos un archivo por concepto relevante.
No importar carpetas: las declaraciones del mismo target se ven entre sí con
acceso internal (predeterminado). Los imports cargan módulos como Foundation.

## Desde React y TypeScript

| React / TypeScript | SwiftUI / Swift |
| --- | --- |
| Componente funcional y JSX | struct que conforma View y propiedad body |
| Props | Propiedades recibidas en init, normalmente let |
| useState | @State para estado local de la vista |
| Valor + callback de actualización | @Binding para editar estado del propietario |
| Hook con estado y acciones | ViewModel ObservableObject con @Published |
| Instancia de estado propiedad de la pantalla | @StateObject |
| Objeto observable recibido de otra vista | @ObservedObject |
| interface | protocol |
| Implementación de servicio inyectada | Tipo que conforma un protocol, recibido por init |
| Promise / async-await | async throws / try await y Task |
| fetch | URLSession, envuelta aquí por HTTPClient |
| null / undefined | nil, permitido por un tipo opcional T? |
| Unión discriminada | enum con valores asociados cuando haga falta |

@MainActor serializa el estado de presentación y el árbitro local. No equivale a
hacer cualquier trabajo pesado en el hilo principal: inferencia, decodificación
costosa y cámara deben diseñarse fuera de él. No lanzar trabajo desde body, que
SwiftUI puede reevaluar repetidamente. Usar acciones o .task y controlar cancelación.

Se usa ObservableObject para conservar iOS 16. La vista posee su ViewModel con
@StateObject; su estado publicado actualiza la presentación. No se añade Redux,
un contenedor de inyección ni librerías de navegación para este scaffold.

## Flujo de ejemplo

DestinationView -> DestinationViewModel -> NavigationPlanning
                                      -> UnavailableNavigationService (actual)
                                      -> MapKitNavigationService (por implementar)

AppDependencies selecciona la implementación. El servicio actual lanza un error
explícito. Sustituirlo por un adaptador real o un fake de pruebas; no meter MapKit
en la vista. El ejemplo solo calcula una ruta: empezar un trayecto requiere comprobar
que la seguridad local esté disponible.

## Trabajo por funcionalidad

| Área | Siguiente implementación | Integración |
| --- | --- | --- |
| Audio | Cola, política y AudioArbiterService | AVSpeechSynthesizer mediante AudioPlaying |
| Safety | Cámara, inferencia y distancia confiable | AVFoundation, Vision/Core ML, ARKit |
| Navigation | Cálculo, seguimiento y eventos de giro | MapKit y CoreLocation |
| Narration | Servicio remoto y control de frecuencia | HTTPClient, POST /narration |
| Users | Sesión, DTOs y autenticación | API /users, tokens en Keychain |
| Places | Confirmar contrato de favoritos con backend | El backend actual expone rutas, no asumir CRUD de favoritos |
| Settings | Preferencias y consumo por TTS | Persistencia local de preferencias si se requiere |

Agregar Data/ o Presentation/ cuando exista implementación; no crear repositorios
ni interfaces vacías para cada clase. Mantener tests por funcionalidad conforme crezcan.

## Audio y seguridad

Seguridad y navegación producen eventos locales; narración aporta texto remoto.
Todos llegan a un único árbitro por sesión y solo su reproductor llama al TTS.
Ningún detector, ViewModel ni servicio remoto debe reproducir por su cuenta.

El backend Python contiene un prototipo de reglas: trasladar sus escenarios, no
invocar su cola por HTTP. El scaffold Swift todavía no implementa el árbitro.

Reglas conocidas:
- P1 interrumpe P2/P3. Misma prioridad conserva FIFO por recepción, no createdAt.
- P2 solo interrumpe P3 si el contexto del giro lo exige.
- P3 interrumpido se descarta.
- P2 interrumpido se reevalúa; definir reinicio desde el comienzo como en el prototipo.
- Relevancia combina vencimiento y validez del contexto. No confundirla con estado.

Los umbrales del spike siguen pendientes de resolver; no se codifican números aquí.
AudioDecisionContext expresa datos de decisión sin inventar cómo se calculan.
PlaybackToken identifica cada intento, para ignorar callbacks antiguos incluso si
se vuelve a reproducir el mismo mensaje. El adaptador AVSpeechSynthesizer debe mapear
cada utterance a su token; sus callbacks se entregan al árbitro en MainActor.

play inicia sin esperar a que termine toda la locución. stop detiene el audio antes
de permitir otro inicio. La cola acepta eventos durante reproducción. Hace falta
probar fallos y cancelación además del camino normal.

Antes de usar sensores, agregar descripciones de permisos a project.yml, solicitar
consentimiento y manejar rechazo, falta de hardware y modo reducido. No anunciar
“listo” sin seguridad inicializada. Para la app real faltan anuncios VoiceOver,
feedback háptico y pruebas accesibles en dispositivo; etiquetas de controles no
sustituyen ese trabajo.

## Contratos de backend

DTOs Codable pertenecen a Data; convertirlos a modelos locales en el adaptador.
No equiparar NarrationPriorityDTO.urgent con AudioPriority.immediateRisk: riesgo
inmediato es una decisión local. Configurar la URL del entorno al crear el servicio;
no incrustar secretos. Tokens no van a UserDefaults ni al repositorio.

El HTTPClient comprueba códigos HTTP, pero no implementa autenticación, reintentos
ni política offline. Inyectar una sesión o un fake al probar. Nunca utilizarlo en
el loop de seguridad.

## Validación y colaboración

1. Elegir la funcionalidad y acordar cambios de contrato con el equipo.
2. Crear el adaptador y probar reglas sin hardware mediante fakes.
3. Conectar en AppDependencies y presentar estado mediante el ViewModel.
4. Ejecutar swift test para código portable.
5. Regenerar Xcode y ejecutar el scheme lumio en simulador; probar sensores en iPhone.

XcodeGen incluye automáticamente archivos dentro de Sources/LumioFrontend y Tests.
No agregar otro @main. No editar el .pbxproj generado. Si se crean recursos fuera
del flujo Xcode, declararlos también en Package.swift cuando SwiftPM los necesite.

Referencias oficiales:
- https://developer.apple.com/documentation/swiftui/stateobject
- https://docs.swift.org/latest/documentation/packagemanagerdocs/introducingpackages/
