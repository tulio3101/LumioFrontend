# HU: Gestionar Disponibilidad de la Narración (SCRUM-41)

Como usuario de Lumio, quiero que la aplicación gestione la disponibilidad del servicio de
narración para saber cuándo puede proporcionar descripciones del entorno y continuar funcionando
aunque este servicio no esté disponible.

Épica SCRUM-16 (Narración del entorno). Subtareas: SCRUM-280 (estados), SCRUM-281 (monitoreo),
SCRUM-282 (manejo de la indisponibilidad), SCRUM-283 (integración con iOS y AudioArbiter) y
SCRUM-284 (pruebas). Depende de la narración a pedido (SCRUM-38,
`docs/HU-narracion-del-entorno.md`) y automática (SCRUM-40,
`docs/HU-actualizar-narracion-ante-cambios-de-entorno.md`).

## Qué había antes

- El botón «Describir entorno» ya decía el motivo de cada falla (sin conexión, servicio no
  disponible, tardó demasiado) y las automáticas fallaban en silencio con una pausa creciente.
- Existían `NarrationAvailability`, un `NarrationAvailabilityMonitor` y un health check a la URL
  base, pero no estaban conectados a nada ni tenían pruebas. Los avisos eran P3, en el contexto
  de las descripciones y sin vibración, y el health check no sabía si el VLM funcionaba.

## Qué hace ahora

### Estados (SCRUM-280)

`NarrationAvailability`: `checking` (al empezar la ruta; no bloquea), `available` y
`unavailable(NarrationOutage)`, con `offline` (sin red o sin llegar al servidor) o `serviceDown`
(el servidor responde, pero la narración está caída, saturada o sin configurar).

### Monitoreo (SCRUM-281)

`NarrationAvailabilityMonitor` corre mientras se ve la ruta activa (lo arrancan y paran
`startAutoUpdates()` / `stopAutoUpdates()` de `EnvironmentNarrationService`):

- Sin red (`ConnectivityObserving`) marca `offline` sin llamar al servidor.
- Con red consulta `GET /vision/status` (`RemoteNarrationStatusService`): sin sesión, sin foto y
  sin gastar cupo. Timeout de 4 s. Un backend anterior sin ese endpoint (404) cuenta como
  disponible; una falla de red, como `offline`; un 5xx o una respuesta ilegible, como
  `serviceDown`.
- Disponible: vuelve a mirar cada 30 s. Caída: reintenta a los 2, 4, 8, 16 y 30 s (o lo que pida
  el backend en `retry_after_seconds`) y en cuanto vuelve la red.
- Cada solicitud real también cuenta: una descripción que llega confirma que funciona; una falla
  de red o del servicio (sin conexión, 5xx, timeout, sin configurar) pide comprobar ya. El límite
  de uso (429), la cámara, la sesión o una respuesta vieja no son una caída.

El backend (`tulio3101/Lumio`, mismo SCRUM-41) responde `degraded` tras 3 fallas seguidas del VLM,
durante 30 s desde la última, y `not_configured` si el entorno no tiene VLM.

### Aviso al usuario (SCRUM-283)

Una vez al caer y una al volver, por el AudioArbiter como P2 `.routeInformation` en el contexto
`narration-status` (`NarrationAudio.statusContextID`, distinto del de las descripciones), con
vibración (`HapticPreferencesService`) mediante el `FeedbackCatalog`:

| Momento | Audio | Vibración |
|---|---|---|
| Se cae sin red | «Narración no disponible: no hay conexión. La detección de obstáculos sigue activa.» | `narrationUnavailable`: un toque medio y uno suave |
| Se cae el servicio | «Narración no disponible por ahora. La detección de obstáculos sigue activa.» | `narrationUnavailable` |
| Vuelve | «Narración disponible de nuevo.» | `narrationAvailable`: un toque suave y uno medio |

- Si el usuario acaba de oír el motivo al pulsar el botón, la caída no se le repite; la vuelta sí
  se anuncia.
- Al volver se cancela un «no disponible» que aún no hubiera sonado.
- Si la narración vuelve porque llegó una descripción, no se dice «disponible de nuevo»: la
  descripción ya lo demuestra.
- Las dos vibraciones se pueden apagar en Preferencias > Vibración y se respaldan en
  `haptic_disabled_events` (`narrationUnavailable`, `narrationAvailable`).
- En pantalla, el botón muestra «Narración no disponible» (icono `eye.slash`) y VoiceOver lee el
  valor «No disponible» y una pista que recuerda que la detección sigue activa. La vista no
  locuta nada.

### Política durante la caída (SCRUM-282)

- **Automáticas:** `AutoNarrationScheduler` no toma foto (`skipped(.narrationUnavailable)`).
  No hay cola: una foto vieja ya no describe lo que el usuario tiene delante (ADR-308, 4 s).
- **Botón:** no se toma ni se envía la foto. Responde enseguida, P2: «La narración sigue sin estar
  disponible. Te aviso cuando vuelva. La detección de obstáculos sigue activa.» (o «sigue sin
  conexión») y pide una comprobación inmediata; si el servicio volvió, se oye «Narración
  disponible de nuevo» y la siguiente pulsación funciona. El botón sigue activo para eso.
- **Reanudación:** al pasar de caída a disponible, `EnvironmentNarrationService` llama a
  `AutoNarrationScheduler.resume()`, que olvida la pausa por fallas (30/60/120 s); la escena de
  referencia y el tope de la ruta se conservan.

### Seguridad intacta

Nada de esto toca `SafetyService`, la detección de obstáculos, los giros ni la navegación: el
monitor solo decide si se envían fotos y qué se dice de la narración. La foto de la narración se
sigue tomando del `ARSession` de la seguridad sin frenarlo, y durante una caída ni siquiera se
pide.

## Criterios de aceptación

| Criterio | Cómo se cumple |
|---|---|
| Identifica cuándo la narración está disponible | `GET /vision/status` + red; estado `available` |
| Detecta pérdida de conectividad o indisponibilidad | `ConnectivityObserving`, `unreachable`, `degraded`/`not_configured` y las fallas reales |
| Retroalimentación cuando no está disponible | P2 + vibración una vez por caída; botón y VoiceOver muestran el estado |
| No afecta la detección ni la seguridad | El monitor no depende de la seguridad; los avisos dicen que la detección sigue activa |
| Reanuda cuando vuelve el servicio | Aviso «disponible de nuevo», `resume()` de las automáticas, botón operativo |
| Gestiona las solicitudes durante la caída | Automáticas descartadas sin foto; botón responde al instante y comprueba de nuevo |

## Piezas

- `Features/Narration/Domain/NarrationAvailability.swift`: estados, `NarrationServiceStatus`,
  `NarrationStatusChecking` y `NarrationAvailabilityObserving` (con la política documentada).
- `Features/Narration/Data/RemoteNarrationStatusService.swift`: `GET /vision/status` (reemplaza
  `LumioAPIHealthChecker`).
- `Features/Narration/Application/NarrationAvailabilityMonitor.swift`: sondeo, espera creciente y
  avisos.
- `EnvironmentNarrationService`: `availability`, `narrationAvailability` (publicado) y la política
  del botón; `AutoNarrationScheduler`: `narrationUnavailable` y `resume()`.
- `FeedbackCatalog`: `narrationUnavailable(NarrationOutage)` y `narrationAvailable` (P2 con
  vibración). `HapticCue`: `narrationUnavailable`, `narrationAvailable`.
- `AppDependencies`: conecta el monitor (sin cambios en `RootView` ni `LumioApp`).
- `ActiveRouteView`: estado en el botón «Describir entorno».

Pruebas en `Tests/LumioFrontendTests/NarrationAvailabilityTests.swift` (swift-testing).

## Pendiente

- Probar en un iPhone con VoiceOver cortando y devolviendo la red durante una ruta.
