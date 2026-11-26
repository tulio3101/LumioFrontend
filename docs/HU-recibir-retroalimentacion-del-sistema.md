# HU: Recibir Retroalimentación del Sistema (SCRUM-31)

Como usuario con discapacidad visual, quiero recibir retroalimentación por audio y vibración de
lo que hace la app (acciones, errores y eventos críticos) para saber qué está pasando sin mirar
la pantalla.

Depende del AudioArbiter (SCRUM-42) y del motor háptico (preferencias hápticas). Esta HU define
la matriz de eventos y la conecta a los flujos; **la cola, la prioridad y la reproducción son
del árbitro**, y el patrón y las preferencias de vibración son del motor háptico.

## Un solo camino

`FeedbackCatalog` (`Features/Audio/Domain/FeedbackCatalog.swift`) traduce un `FeedbackEvent` a
un `FeedbackItem` (mensaje del árbitro + patrón háptico opcional). `FeedbackCatalog.emit` envía el
mensaje a `AudioArbitrating.receive` y el patrón a `HapticFeedbackPlaying.play`. No hay otro
gestor de audio ni de vibración:

- Solo `SpeechAudioPlayer` (el reproductor del árbitro) usa APIs de sonido. Lo vigila
  `onlyTheArbiterPlayerUsesPlaybackAPIs` (SCRUM-42).
- Solo `UIKitHapticFeedback` (el motor háptico) usa generadores de vibración. Lo vigila
  `noHapticOutputOutsideTheHapticEngine` (esta HU).
- Una alerta P1 que empieza a sonar vibra `criticalAlert` desde el árbitro
  (`HapticPreferencesService.audioMessageChanged`), aunque el usuario haya apagado la vibración.

El texto de cada aviso se reutiliza de los anuncios que ya existían (`RouteAnnouncements`,
`SafetyAudio`, `EmergencyAnnouncements`, `SessionAudio`, `EnvironmentNarrationMessages`…): lo que
se muestra en pantalla y lo que se locuta no cambian.

## Matriz (SCRUM-201)

Prioridades: **1 seguridad** (`.immediateRisk`), **2 navegación y avisos del sistema**
(`.routeInformation`), **3 narración e información** (`.environmentInformation`).
«Siempre» marca los patrones que vibran aunque la vibración esté apagada (`HapticCue.alwaysOn`).

| Evento | Cuándo | Prioridad | Vibración | Emite |
|---|---|---|---|---|
| `routeCreated` | Ruta lista | 2 | `routeReady` | RouteCreationService |
| `routeModified` | Destino cambiado | 2 | `routeReady` | RouteModificationService |
| `routeRecalculated` | Ruta recalculada | 2 | `routeReady` | RouteRerouteService |
| `routeFinished` / `arrival` | Ruta finalizada o llegada | 2 | `routeFinished` | RouteFinishService |
| `routeCreationFailed` | No se pudo crear la ruta | 2 | `routeFailed` | RouteCreationService |
| `routeModificationFailed` | No se pudo cambiar el destino | 2 | `routeFailed` | RouteModificationService |
| `rerouteFailed` | No se pudo recalcular | 2 | `routeFailed` | RouteRerouteService |
| `offline(destination:)` | Recalcular sin conexión | 2 | — | RouteRerouteService |
| `backendError` | Servicio no disponible | 2 | `routeFailed` | — (reservado) |
| `modelUnavailable` | Se cae la detección | 1 | `criticalAlert` (árbitro) | SafetyService |
| `detectionRecovered` | Vuelve la detección | 2 | — | SafetyService |
| `fullMode` / `reducedMode` | Cámara y seguridad listas | 2 | `safetyReady` (siempre) | SafetyService |
| `thermalPaused` | Pausa por calor crítico | 1 | `warning` (siempre) | SafetyService |
| `thermalResumed` | Se reanuda tras el calor | 2 | — | SafetyService |
| `lowLight` | Poca luz | 1 | `warning` (siempre) | LowLightDetector |
| `lowLightRecovered` | Vuelve la luz | 3 | — | LowLightDetector |
| `permissionsDenied` | Sin cámara | 3 | — | — (reservado) |
| `emergencyActivated` | Empieza la cuenta atrás | 1 | `emergencyActivated` (siempre) | EmergencyService |
| `emergencyCountdown` | Recordatorio a los 5 s | 1 | `criticalAlert` (árbitro) | EmergencyService |
| `emergencyCancelled` | Alerta cancelada | 1 | `criticalAlert` (árbitro) | EmergencyService |
| `emergencySending` | Enviando | 1 | `criticalAlert` (árbitro) | EmergencyService |
| `emergencySent` | Alerta enviada | 1 | `emergencySent` (siempre) | EmergencyService |
| `emergencyFailed` | Alerta no enviada (recuerda el 123) | 1 | `emergencyFailed` (siempre) | EmergencyService |
| `narrationUnavailable` | Cae la narración | 2 | `narrationUnavailable` | NarrationAvailabilityMonitor |
| `narrationAvailable` | Vuelve la narración | 2 | `narrationAvailable` | NarrationAvailabilityMonitor |
| `sessionClosed` | Sesión cerrada | 2 | — | SessionTeardown |
| `sessionExpired` | Sesión vencida con ruta activa | 2 | — | SessionExpiryCoordinator |

Los avisos de obstáculos y desniveles (`ObstacleAnnouncer`), las indicaciones de giro
(`TurnGuidanceMonitor`) y la narración (`NarrationAudio`) no pasan por el catálogo porque su texto
depende de la detección, la ruta o el VLM; sí van por el mismo árbitro y el mismo motor háptico,
con prioridad 1, 2 y 3 respectivamente.

## Cambios en los flujos (SCRUM-202 a 205)

- Las rutas (crear, modificar, recalcular, finalizar), la emergencia, la seguridad (calor,
  recuperación de la detección) y la sesión (cerrada, vencida) emiten por `FeedbackCatalog.emit` en lugar de armar el mensaje y
  la vibración por separado. El texto, la prioridad, el contexto y la clave no cambian.
- `LowLightDetector` ya no tiene su propio `UINotificationFeedbackGenerator`: recibe el motor
  háptico y emite `lowLight` / `lowLightRecovered`. Ahora respeta las preferencias hápticas
  (`warning` vibra siempre) y la recuperación ya no vibra, solo se locuta (P3). Deja de depender
  de UIKit y se prueba en todas las plataformas.
- La emergencia sigue cancelando su aviso anterior antes de emitir el siguiente.

## Anuncios de VoiceOver

`announceForAccessibility` (`Shared/UI/AccessibilityAnnouncement.swift`) no es audio de Lumio:
pide al lector de pantalla que lea un estado de la interfaz. Se permite solo en la capa de
presentación y para lo que el árbitro no dice. Usos actuales, revisados en esta HU (ninguno
repite un mensaje del árbitro):

| Dónde | Qué anuncia |
|---|---|
| RoutePlannerView, RecentRoutesView | «Calculando ruta hacia…» al elegir destino; número de sugerencias |
| ActiveRouteView | «Consultando tu ruta.» mientras se lee el GPS |
| AccountFormView | Errores de validación del formulario y fallas que no se locutan (`!isAnnouncedByAudio`) |
| TrustedContactsViewModel | Máximo de contactos al abrir el formulario (el servicio no habla en ese caso) |

Un anuncio nuevo que repita lo que ya dice el árbitro debe quitarse o marcarse como
`isAnnouncedByAudio`, como en `docs/HU-iniciar-sesion-con-google.md`.

## No bloquea módulos críticos

`emit` es síncrono y solo encola: no espera a que termine el audio ni la vibración. Sin árbitro la
vibración sigue, y sin motor háptico el audio sigue. La seguridad no espera por ningún aviso de
navegación o narración.

## Pruebas (SCRUM-206)

`Tests/LumioFrontendTests/FeedbackMatrixTests.swift`:

- cada evento tiene la prioridad y el patrón de la matriz y un texto no vacío;
- las alertas de seguridad y emergencia son P1 y nunca usan un patrón que el usuario pueda apagar;
- todo error de ruta y de emergencia se locuta y vibra; los de emergencia recuerdan el 123;
- `emit` va al árbitro y al motor háptico, y cada canal funciona sin el otro;
- poca luz: P1 con `warning` por el motor háptico, sin repetir; la recuperación es P3 sin vibrar;
- emergencia: activar y cancelar suenan desde el catálogo y reemplazan el aviso anterior;
- conflictos en el árbitro real: una P1 interrumpe una P2 que luego vuelve; una P2 espera detrás
  de una P1; una P3 no interrumpe una indicación; un aviso repetido no se encola dos veces;
- ningún generador de vibración fuera del motor háptico.

Las pruebas existentes de rutas, emergencia y preferencias hápticas siguen pasando sin cambios.

## Validación en el iPhone

1. Con VoiceOver, crear una ruta: se oye «ruta lista» y vibra.
2. Activar el modo avión y pedir recalcular: se oye el aviso sin conexión.
3. Tapar la cámara durante la ruta: se oye «Poca luz» y vibra aunque la vibración esté apagada;
   destaparla: se oye «Luz suficiente de nuevo» sin vibrar.
4. Con una indicación sonando, provocar una alerta de obstáculo: la alerta corta la indicación y
   la indicación vuelve después.
5. Activar la emergencia y cancelarla: se oye cada paso y vibra al activar.

Compilación y pruebas de iOS pendientes de CI en macOS al momento del commit.
