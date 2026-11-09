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

## Flujo de Crear Ruta (SCRUM-8), Modificar Ruta (SCRUM-9) y Consultar Ruta (SCRUM-23)

Pantallas (un DestinationViewModel compartido):
  DestinationView    inicio del trayecto; una acción principal según haya o no ruta activa
  RoutePlannerView   hoja para indicar el destino (con sugerencias), calcular y
                     recuperarse de fallos; modo `.create` o `.changeDestination`
  ActiveRouteView    indicación actual con «Repetir indicación», resumen, estado del
                     trayecto («¿Cómo voy?»), estado de guardado, «Cambiar destino» y
                     pasos como línea de tiempo. «Ruta actualizada» se muestra una sola vez.
El ViewModel clasifica cada fallo por su salida (corregir destino, abrir Ajustes,
reintentar) para que la pantalla ofrezca la acción adecuada.

Sugerencias: DestinationViewModel -> DestinationSuggesting -> MapKitDestinationSuggester
(MKLocalSearchCompleter, espera 0,3 s tras la última tecla, mínimo 3 letras, máximo 5).
Elegir una sugerencia confirma el destino como `DestinationRequest.place`; si no se puede
ubicar, se usa su texto como `.query` para que el servicio locute el fallo.

DestinationViewModel -> RouteCreating / RouteModifying
  WalkingRoutePlanner (Application), común a crear y modificar:
    1. CurrentLocationProviding  -> CoreLocationCurrentLocationProvider (lectura nueva cada vez)
    2. DestinationGeocoding      -> MapKitDestinationGeocoder (MKLocalSearch cerca del usuario)
    3. WalkingRouteCalculating   -> MapKitWalkingRouteCalculator (MKDirections, .walking)
    4. NavigationInstructionBuilder normaliza los pasos
  RouteCreationService: ruta nueva -> copia local -> "Ruta lista" + primera instrucción
  RouteModificationService: misma ruta (mismo id), revisión +1, current_step 0 -> copia
    local -> invalida el audio del recorrido anterior -> "Ruta actualizada" + primera
    instrucción. Si falla antes de guardar, la ruta anterior queda intacta y se locuta
    "No se pudo cambiar el destino… Sigues con la ruta hacia X".
  ActiveRouteSynchronizer -> RemoteActiveRouteService (con AuthorizedHTTPClient):
    ruta nueva: PUT /places/routes/active; cambio de destino: PUT
    /places/routes/{remoteID}/destination (si el backend ya la cerró, 404/409, se guarda
    como ruta nueva). No sobrescribe una revisión local más nueva.
  En Linux y macOS (SwiftPM): UnavailableNavigationService.

Repetir la indicación: DestinationViewModel -> InstructionRepeating ->
RouteInstructionRepeater. Reenvía al árbitro el mismo mensaje del paso actual (contexto de
la revisión vigente y clave `step-<n>`): si aún espera turno o está sonando no se duplica,
y si ya terminó vuelve a sonar.

Consultar Ruta Actual (SCRUM-23): Magic Tap de VoiceOver en toda la pestaña Trayecto,
«¿Cómo voy?» en el inicio y en «Tu ruta», o la acción «Consultar ruta» de VoiceOver ->
DestinationViewModel.queryRouteStatus -> RouteStatusQuerying -> RouteStatusService:
  1. ActiveRouteStoring.load(): la ruta sale solo de la copia local (sin backend). Sin
     ruta: «No tienes una ruta activa…»; copia ilegible: «No se pudo leer la ruta…».
  2. CurrentLocationProviding: una lectura de GPS (no necesita internet). Si falla, el
     avance se calcula con `currentStep` y se avisa de que es aproximado.
  3. RouteProgressEstimator: aproxima la ruta con tramos rectos (origen -> punto de cada
     maniobra -> destino), proyecta la posición sobre el tramo más cercano y obtiene la
     siguiente indicación, lo recorrido, lo que falta (tramo restante + pasos siguientes),
     el porcentaje y el tiempo restante. A menos de 25 m del destino, «Estás llegando».
  4. RouteStatusAnnouncements arma el texto (destino, avance, siguiente indicación); la
     pantalla muestra las mismas frases. El mensaje P2 va en el contexto de la revisión
     con clave `route-status`: no se duplica y se descarta si cambia el destino.
No se guarda el paso estimado; el ViewModel solo lo usa para mostrar y repetir la misma
indicación que se acaba de oír (`guidanceRoute`). Avanzar `currentStep` es de SCRUM-312.

Audio de las instrucciones: cada revisión del recorrido tiene su propio `contextID`
(`route-<id>` y luego `route-<id>-r<n>`). El árbitro deja invalidados para siempre los
contextos y deduplica por clave dentro de un contexto, así que reutilizar el contexto
silenciaría las instrucciones nuevas o las haría pasar por duplicadas de las viejas.

## Sesión (JWT)

RemoteAuthenticationService (POST /users, /users/login) guarda los tokens en
KeychainTokenStore. AuthorizedHTTPClient añade `Authorization: Bearer`, ante un 401
renueva una sola vez con /users/refresh y repite la petición; si el refresh se rechaza,
borra la sesión (la ruta queda pendiente en el teléfono). StoredSessionService decide la
pantalla inicial sin red. SignOutService (Preferencias) revoca la sesión, borra la ruta
local y detiene el audio.

La ruta está lista en cuanto existe la copia local: la guía no depende del backend.
Si el backend falla, la ruta queda pendiente (remoteID nil o hasPendingDestinationChange)
y restoreActiveRoute() reintenta guardarla al volver a la pantalla. Cada fallo es un RouteCreationError con
su anuncio en RouteAnnouncements, y la pantalla muestra el mismo texto. Nunca se
locuta desde la vista ni desde el ViewModel.

Contratos para las HUs siguientes:
- Indicar Destino por Voz (SCRUM-313) entrega `DestinationRequest.query` (texto
  confirmado) o `.place` (ya geocodificado) a `DestinationViewModel.createRoute(to:)`
  o, con una ruta activa, a `DestinationViewModel.changeDestination(to:)` (Modificar
  Ruta exige pedir el cambio por voz con confirmación por audio).
- Guiar Giros (SCRUM-312) lee la copia local (`ActiveRouteStoring`), usa
  `RouteStep.maneuverCoordinate` para anunciar a tiempo y
  `NavigationInstructionBuilder.message(for:in:now:)` para crear el mensaje P2. Usa
  siempre `NavigationInstructionBuilder.contextID(for: route)`: cambia con cada
  revisión; al crear una ruta o cambiar su destino se invalida el contexto anterior.
  Al cambiar el destino `currentStep` vuelve a 0. Puede reutilizar
  `RouteProgressEstimator` para decidir cuándo avanzar `currentStep`; Consultar Ruta
  ya usa ese paso cuando no hay GPS.
- Finalizar Ruta (SCRUM-10) borra la copia local con `ActiveRouteStoring.clear()`.

Antes de empezar un trayecto con asistencia completa, hay que comprobar que la seguridad
local esté disponible.

## Trabajo por funcionalidad

| Área | Siguiente implementación | Integración |
| --- | --- | --- |
| Audio | Conectar productores y validar en dispositivo | Cola/árbitro implementados; AVSpeechSynthesizer mediante AudioPlaying |
| Safety | Cámara, inferencia y distancia confiable | AVFoundation, Vision/Core ML, ARKit |
| Navigation | Seguimiento y eventos de giro (SCRUM-312) | Crear Ruta implementada con MapKit y CoreLocation |
| Narration | Servicio remoto y control de frecuencia | HTTPClient, POST /narration |
| Users | Inicio de sesión con Google | Correo, Keychain, Bearer y refresh implementados |
| Places | Confirmar contrato de favoritos con backend | El backend actual expone rutas, no asumir CRUD de favoritos |
| Settings | Preferencias y consumo por TTS | Persistencia local de preferencias si se requiere |

Agregar Data/ o Presentation/ cuando exista implementación; no crear repositorios
ni interfaces vacías para cada clase. Mantener tests por funcionalidad conforme crezcan.

## Audio y seguridad

Seguridad y navegación producen eventos locales; narración aporta texto remoto.
Todos llegan a un único árbitro por sesión y solo su reproductor llama al TTS.
Ningún detector, ViewModel ni servicio remoto debe reproducir por su cuenta.

El backend Python contiene un prototipo de reglas: trasladar sus escenarios, no
invocar su cola por HTTP. La implementación Swift está en Audio/Application y la
cola/política en Audio/Domain. AppDependencies mantiene una instancia del árbitro
con el reproductor nativo en plataformas Apple.

Reglas conocidas:
- P1 interrumpe P2/P3. Misma prioridad conserva FIFO por recepción, no createdAt.
- P2 solo interrumpe P3 si el contexto del giro lo exige.
- P3 interrumpido se descarta.
- P2 interrumpido se reevalúa; definir reinicio desde el comienzo como en el prototipo.
- Relevancia combina vencimiento y validez del contexto. No confundirla con estado.

Los umbrales del spike siguen pendientes de resolver; no se codifican números aquí.
AudioDecisionContext expresa datos de decisión sin inventar cómo se calculan:
urgentNavigationMessageIDs contiene los mensajes de giro urgentes e
invalidatedContextIDs identifica giros/rutas/escenas que ya no son válidos.
updateContext reemplaza la instantánea y reevalúa los pendientes inmediatamente.
El productor mantiene el contexto actualizado; un mensaje P2 sin marca urgente espera.
PlaybackToken identifica cada intento, para ignorar callbacks antiguos incluso si
se vuelve a reproducir el mismo mensaje. El adaptador AVSpeechSynthesizer debe mapear
cada utterance a su token; sus callbacks se entregan al árbitro en MainActor.

play inicia sin esperar a que termine toda la locución. stop detiene el audio antes
de permitir otro inicio. La cola acepta eventos durante reproducción. Las pruebas
portables cubren prioridad, FIFO, interrupciones, tokens antiguos, expiración y
fallos de inicio. Si el inicio falla, el mensaje se descarta y se informa mediante
onPlaybackError; los siguientes mensajes siguen procesándose. Un P2 interrumpido
conserva su orden original y se reproduce desde el inicio si todavía es relevante.

La integración nativa aún requiere pruebas en iPhone de stop/reinicio y ducking,
así como manejo de interrupciones externas (llamadas, Siri), rutas de audio y ciclo
de vida de la sesión. El código portable no valida esas condiciones del sistema.

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


## Integración de la cola

Todos los productores llaman a receive en MainActor; no llaman al reproductor.
El árbitro posee copias de los mensajes (struct): observar currentMessage,
pendingMessages u onMessageChanged; modificar el valor original no modifica la cola.
Actualizar el contexto para invalidar un giro, no mutar el mensaje original.
Para reevaluar vencimientos sin nuevos eventos, el coordinador de trayecto puede
llamar a processNext; siempre se comprueban antes de reproducir. El contexto nuevo
invalida pendientes, no interrumpe automáticamente una locución activa por caducidad.

Los callbacks de estado/error son para observación; no deben iniciar operaciones
reentrantes del árbitro de forma síncrona. Para efectos derivados, programar una
Task en MainActor. No hay historial persistente ni endpoints para esta cola.

El reproductor debe notificar únicamente el token del intento que terminó. El
adaptador nativo elimina los tokens al detener y usa un único sintetizador. Los
productores reales todavía no están conectados y no se agrega una pantalla de
prueba de voz a la navegación del usuario.

## HU: descartar mensajes duplicados u obsoletos

Implementada en AudioDeduplicationPolicy y AudioArbiterService. No requiere API ni
base de datos. El contrato para productores futuros es:

- `deduplicationKey`: identidad estable del evento/información, no el texto.
- `contextID`: grupo de información comparable (ruta, giro o escena). Usar IDs
  distintos para contextos independientes; conservar los contextos invalidados en
  las instantáneas posteriores mientras puedan llegar respuestas de ellos.
- `captureSequence`: UInt64 creciente asignado al capturar, no al recibir la
  narración. Solo participa para P3 con contextID. La misma captura conserva su
  secuencia aunque la respuesta llegue tarde. Al iniciar otro contexto, usar otro ID.

Reglas:
1. Un UUID activo o pendiente repetido se ignora sin cambiar el estado del original.
2. P2/P3 con la misma clave no vacía, contexto no vacío y prioridad se consideran
   duplicados mientras el mensaje anterior siga siendo relevante y activo/pendiente.
   El nuevo se notifica como descartado. Sin clave o contexto no se aplica ese filtro.
3. P1 no participa en deduplicación por clave ni comparación de capturas. Sigue
   sujeto a vencimiento/contexto y a la protección por UUID.
4. P3 de captura más reciente reemplaza pendientes de capturas anteriores del mismo
   contexto, aunque comparta clave. No interrumpe una narración activa por novedad.
5. Solo un mensaje relevante y aceptado actualiza la última secuencia por contexto.
   Una respuesta inferior a esa secuencia se descarta aunque la narración reciente
   ya haya terminado. Secuencias iguales no son antiguas: la clave/UUID decide su
   duplicidad. Sin secuencia no se puede inferir cuál captura es anterior.
6. No hay historial temporal de duplicados reproducidos. Sí hay un registro de la
   última secuencia aceptada por contexto: se libera al invalidar ese contexto o
   ejecutar resetSession. resetSession detiene audio, descarta activos/pendientes,
   limpia contexto/registro e invalida callbacks anteriores. Invocarlo al cerrar el
   trayecto; un nuevo trayecto puede usar otra instancia del árbitro.
7. Los supervivientes conservan su orden original. La narración nueva ocupa su
   posición real de llegada, no la del mensaje reemplazado.

La vigencia se comprueba antes de modificar pendientes; los vencidos se limpian
antes de comparar duplicados. Los cambios se observan mediante onMessageChanged.
Como en el resto del árbitro, esos callbacks deben ser observadores no reentrantes.

Pruebas en `Tests/LumioFrontendTests/AudioDeduplicationTests.swift`: diez escenarios
nuevos cubren duplicados activos/pendientes, UUID, contextos/prioridades diferentes,
metadatos ausentes, protección P1, reemplazo, respuestas fuera de orden, información
nueva inválida, continuidad/FIFO, expiración y limpieza de sesión/contexto.
Resultado de `swift test --cache-path /tmp/lumio-swift-cache`: 23 pruebas pasan
(13 previas + 10 nuevas). Validación portable con reproductor simulado; integración
nativa y productores quedan para la etapa posterior acordada.
