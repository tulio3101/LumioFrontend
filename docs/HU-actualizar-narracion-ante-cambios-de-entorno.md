# HU: Actualizar Narración ante Cambios de Entorno (SCRUM-40)

Como usuario de Lumio, quiero recibir nuevas descripciones cuando el entorno cambie
significativamente para evitar información repetitiva o desactualizada.

Depende de la narración a pedido (SCRUM-38, `docs/HU-narracion-del-entorno.md`), del consentimiento
(SCRUM-324) y de las prioridades del AudioArbiter (SCRUM-42, SCRUM-44). Decisiones en el ADR-308
(loop lento de narración).

## Qué hace

Mientras se ve la ruta activa (`ActiveRouteView`), `AutoNarrationScheduler` revisa cada 5 s si
conviene volver a narrar. Cada revisión recorre estas comprobaciones, de la más barata a la más
cara; la primera que falla termina la revisión sin gastar red:

| # | Comprobación | Si falla |
|---|---|---|
| 1 | Consentimiento vigente (`consentVersionForUpload`, en silencio) | No toma foto ni dice nada |
| 2 | Hay conexión | Espera; no cuenta como falla |
| 3 | No hay otra descripción en vuelo (`isDescribing`) | Espera |
| 4 | Tope de la ruta: 90 solicitudes automáticas | Deja de pedir hasta la próxima ruta |
| 5 | Pausa tras fallas (30 s, 60 s, 120 s) | Espera |
| 6 | Mínimo de 10 s desde la última narración, del botón o automática (20 s con ahorro de batería) | Espera sin tomar foto |
| 7 | Canal de audio libre (`AudioChannelObserving.isChannelFree`) | Espera: nunca se acumula detrás de alertas o indicaciones |
| 8 | Foto del `ARSession` de la seguridad y huella `VNFeaturePrint` | Sin foto útil, espera |
| 9 | La huella se aleja de la última escena narrada (`changeThreshold`) | Misma escena: no se envía nada |

Solo si pasan las nueve se envía **la misma foto** que se comparó a `POST /vision/analyze` con
`trigger=auto`. La primera foto de cada ruta es la escena de referencia y no se narra: la narración
inicial sigue siendo el botón «Describir entorno». Una descripción pedida con el botón también pasa
a ser la escena de referencia, para no repetirla.

## Criterios de aceptación

- **Controla la frecuencia:** mínimo de 10 s entre narraciones, sumando botón y automáticas.
- **Evita solicitudes innecesarias:** con la escena igual (o casi), la foto no sale del teléfono.
  La huella se calcula en el dispositivo.
- **Un cambio significativo genera una solicitud:** distancia entre huellas normalizadas ≥
  `AutoNarrationConfiguration.changeThreshold` (0,35).
- **No reproduce narraciones obsoletas:** solo se pide con el canal libre, la respuesta se
  descarta si llega más de 4 s después de la foto, y el árbitro descarta lo que espere más de 10 s
  o llegue de una captura más vieja que la última aceptada.
- **Respeta el AudioArbiter:** la descripción entra como P3 (`NarrationAudio`), igual que la del
  botón. No interrumpe alertas (P1) ni indicaciones (P2) y una indicación de giro la corta.
- **La pérdida de conexión no afecta el loop de seguridad:** el planificador no depende de la
  seguridad ni la espera. Sin red no hace nada; una falla del backend solo pospone la siguiente
  revisión. Las fallas automáticas **no se locutan** (el botón sí informa las suyas).
- **Controla datos y recursos:** tope de 90 solicitudes por ruta, pausa creciente tras fallas, el
  doble de mínimo con el modo de bajo consumo, y la foto es de 768 px (SCRUM-261). El backend suma
  su propio límite (ver abajo).

## Piezas

- `Features/Narration/Domain/SceneChange.swift`: `SceneSignature` (vector normalizado y distancia),
  `SceneSignatureProviding` y `AutoNarrationConfiguration`.
- `Features/Narration/Data/VisionSceneSignatureProvider.swift`: huella con `VNFeaturePrint`.
- `Features/Narration/Application/AutoNarrationScheduler.swift`: el loop y las decisiones
  (`tick()` devuelve la decisión, para probarla sin esperar el reloj).
- `EnvironmentNarrationService`: `describeEnvironment(trigger:preCapturedFrame:)` reutiliza la foto
  del planificador; con `trigger == .auto` no habla (ni «Describiendo…» ni avisos de falla),
  y expone `lastRequestAt` y `onDescribed`.
- `AudioArbiterService`: `AudioChannelObserving.isChannelFree` (nada suena ni espera).
- `AppDependencies` crea el planificador; `ActiveRouteView` lo inicia al mostrarse la ruta y lo
  detiene al salir o al finalizarla. Retirar el consentimiento (`service.cancel()`) lo detiene.

## Backend (repositorio Lumio)

`trigger=auto` tiene su propio límite: 1 solicitud cada 10 s y 1.200 al día por usuario
(`NARRATION_AUTO_MIN_INTERVAL_SECONDS`, `NARRATION_AUTO_DAILY_LIMIT`). Las 300 restantes del tope de
1.500 quedan para el botón. Una automática rechazada responde 429 `narration_rate_limited`; el
planificador la trata como una falla silenciosa y espera.

## Pruebas

`Tests/LumioFrontendTests/AutoNarrationTests.swift`:

- huella normalizada, vectores vacíos o de distinto tamaño, y pausas 30/60/120 s;
- primera escena como referencia; escena igual no envía; cambio envía `auto` con la misma foto;
- la escena narrada, también con el botón, pasa a ser la nueva referencia;
- mínimo de 10 s (botón y automática cuentan), bajo consumo y tope de la ruta;
- canal ocupado pospone sin tomar foto; respuesta vieja no suena;
- sin conexión, sin consentimiento o sin foto útil: no se hace nada y no se dice nada;
- fallas y 429 silenciosos con pausa creciente, y recuperación;
- retirar el consentimiento detiene el planificador; cada ruta parte de cero;
- el `trigger=auto` viaja en el multipart.

`VisionSceneSignatureProvider`, `ActiveRouteView` y `ARKitFrameSource` solo compilan en iOS: se
validan en el iPhone. Las pruebas de este repositorio no se pudieron ejecutar al escribirlas
(sin toolchain de Swift en el equipo de desarrollo): pendientes de CI en macOS.

## Validación en el iPhone

1. Con el consentimiento aceptado, iniciar una ruta y pedir una descripción con el botón.
2. Quedarse quieto mirando lo mismo: no debe sonar nada nuevo. Revisar en el backend que no llegan
   solicitudes `trigger=auto`.
3. Girar hacia otro lugar (otra calle, un interior): pasados 10 s sin audio sonando, se oye una
   descripción nueva.
4. Con una indicación de giro sonando, cambiar de escena: la descripción espera a que termine, o
   no se pide.
5. Modo avión en medio de la ruta: las alertas de obstáculos siguen, no se oye ningún aviso de
   narración, y al volver la red se reanuda sola.
6. Retirar el consentimiento en Preferencias: no vuelve a salir ninguna foto.
7. **Afinar `changeThreshold`** (0,35): si narra por cambios menores (una persona que pasa) subirlo;
   si no narra al doblar una esquina, bajarlo.
