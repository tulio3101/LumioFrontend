# HU: Narración del Entorno (SCRUM-38)

Como usuario con discapacidad visual, quiero recibir una descripción del entorno que me rodea
para obtener información contextual que no puedo percibir visualmente.

Decisiones en el ADR-308 (loop lento de narración). Depende del consentimiento (SCRUM-324) y
de las prioridades del AudioArbiter (SCRUM-42, SCRUM-44).

## Alcance

Esta HU construye el canal completo, de la foto al audio, con un disparo a pedido: el botón
**«Describir entorno»** en la pantalla de la ruta activa. Quedan para sus propias HU:

- SCRUM-39 (Solicitar Narración): otros mecanismos de solicitud y la gestión de solicitudes
  repetidas más allá de «una sola en vuelo». Ya implementada, ver
  `docs/HU-solicitar-narracion-del-entorno.md`.
- SCRUM-40 (Actualizar ante cambios): el disparo automático por cambio de escena
  (`VNFeaturePrint`, mínimo 10 s entre narraciones, canal libre). Ya implementada, ver
  `docs/HU-actualizar-narracion-ante-cambios-de-entorno.md`.
- SCRUM-41 (Disponibilidad): reanudar sola al volver la red y la política de solicitudes
  durante una caída.

El Magic Tap de la ruta sigue siendo «¿Cómo voy?»; la narración no lo usa.

## Flujo

`EnvironmentNarrationService.describeEnvironment()`:

1. **Consentimiento.** `requireConsentBeforeNarration()`. Sin él no se toma ninguna foto; el
   servicio de consentimiento explica el aviso o recuerda dónde activarlo.
2. **Conexión.** Sin red se dice «Narración no disponible sin conexión» y no se toma foto.
3. **Captura (SCRUM-261).** `ARKitFrameSource.captureNarrationFrame()` toma la foto del mismo
   `ARSession` que usa la seguridad: no abre otra cámara, no pasa por la compuerta del detector
   y no consume frames del loop de seguridad. Espera el primer frame con seguimiento normal
   (cámara no tapada ni movida) hasta 1,5 s. `NarrationFrameEncoder` lo reduce a 768 px de
   lado largo, lo pone en vertical y lo codifica en JPEG con calidad 0,7 desde un `CGImage`
   sin propiedades: **sin EXIF ni GPS**. Todo en memoria.
4. **Envío (SCRUM-262).** `RemoteEnvironmentNarrationService` hace `POST /vision/analyze` con
   sesión, `multipart/form-data` (`image`, `captured_at`, `trigger=gesture`,
   `consent_version`, `language=es`) y timeout de 5 s. Justo antes de enviar se vuelve a
   comprobar el consentimiento: si se retiró durante la captura, no se envía.
5. **VLM y texto (SCRUM-263, 264).** El backend describe la foto con Bedrock y devuelve
   `{text, model, latency_ms}` ya limpio (≤ 2 oraciones). No hay nivel de alerta.
6. **Audio (SCRUM-265).** La descripción entra al árbitro como **P3**
   (`NarrationAudio.message`, contexto `narration`, `captureSequence` creciente): no
   interrumpe alertas (P1) ni indicaciones (P2), una indicación de giro la corta (SCRUM-44) y
   se descarta si espera más de 10 s desde la foto.
7. **Respuesta vieja.** Si llega más de 4 s después de la foto, se descarta y se avisa.

Una sola solicitud en vuelo: mientras se describe, el botón dice «Describiendo el entorno…» y
está desactivado. Si la respuesta tarda más de 1,5 s se locuta «Describiendo el entorno…» (P3,
contexto `narration-status`), que se corta antes de que suene la descripción.

## Fallas (SCRUM-266, 267)

La narración nunca llama al loop de seguridad ni espera por él: una falla solo produce un aviso
por audio (P2, contexto `narration-status`) y la detección sigue igual.

| Causa | Aviso |
|---|---|
| Sin conexión (o la red se cae durante el envío) | Narración no disponible sin conexión. La detección de obstáculos sigue activa. |
| Cámara apagada (sin trayecto activo) | La narración necesita la cámara activa. Inicia un trayecto y vuelve a intentarlo. |
| Sin foto útil en 1,5 s | No pude tomar una foto clara. Sostén el teléfono quieto, mirando al frente, y vuelve a intentarlo. |
| 401 / sesión vencida | La narración del entorno necesita que inicies sesión. (Se borran los tokens.) |
| Sin backend configurado | La narración del entorno no está disponible en esta versión. |
| 429 | Espera unos segundos antes de pedir otra descripción. |
| 503, 500, 403, 413, 422, respuesta ilegible | La narración del entorno no está disponible ahora. La detección de obstáculos sigue activa. |
| Timeout (5 s), 504 o respuesta de más de 4 s | La descripción tardó demasiado y ya no corresponde a lo que tienes delante. Vuelve a intentarlo. |

Retirar el consentimiento (`NarrationConsentService.onRevoked`) cancela la solicitud en vuelo y
lo que estuviera por sonar.

## Pruebas

`Tests/LumioFrontendTests/EnvironmentNarrationTests.swift` (captura, envío y audio con dobles):

- descripción como P3 con la hora de la foto y secuencia creciente;
- sin consentimiento no hay foto; retirarlo durante la captura evita el envío;
- sin conexión, sin cámara o sin foto útil se informa y no se envía nada;
- fallas del backend se informan y no suena ninguna descripción; la siguiente solicitud
  funciona; 401 borra los tokens; tabla de errores → aviso;
- respuesta de más de 4 s descartada;
- una sola solicitud en vuelo, «Describiendo…» en respuestas lentas y cancelación;
- contrato multipart con `POST /vision/analyze`, sin ubicación ni base64.

`ARKitFrameSource`, `NarrationFrameEncoder` y la vista solo compilan en iOS: se validan en el
iPhone.

## Validación en el iPhone

1. Con VoiceOver, aceptar el consentimiento en Preferencias > Narración del entorno.
2. Iniciar una ruta. En «Tu ruta», deslizar hasta «Describir entorno» y tocar dos veces: se oye
   la descripción (o «Describiendo el entorno…» si tarda).
3. Con una indicación de giro sonando, pedir una descripción: la indicación termina primero.
4. Tapar la cámara y pedir una descripción: se oye el aviso de foto no clara.
5. Activar el modo avión y pedir una descripción: se oye el aviso sin conexión y las alertas de
   obstáculos siguen sonando.
6. Retirar el consentimiento con una solicitud en curso: no suena nada más.

Pendiente fuera del código (backend): acceso al modelo en Bedrock y parámetro
`NARRATION_MODEL_ID` (ver README del backend). Compilación y pruebas de iOS pendientes de CI en
macOS al momento del commit.
