# HU: Solicitar Narración del Entorno (SCRUM-39)

Como usuario de Lumio, quiero solicitar una descripción del entorno cuando la necesite para
obtener información visual bajo demanda.

Usa el canal de SCRUM-38 (`EnvironmentNarrationService`: consentimiento, foto del `ARSession`
de la seguridad, `POST /vision/analyze`, descripción como P3 y avisos de falla). Esta HU agrega
cómo se pide y qué pasa al pedir varias veces.

## Cómo se pide

| Mecanismo | Dónde |
| --- | --- |
| Botón «Describir entorno» | «Tu ruta», justo debajo de la indicación (SCRUM-38) |
| Acción de VoiceOver «Describir entorno» | Menú de acciones de la indicación actual, junto a «Consultar ruta» |
| Comando de voz | «Describe el entorno», «describir», «¿qué hay delante?», «¿qué tengo enfrente?», «¿qué hay a mi alrededor?», «¿qué ves?» |

El Magic Tap sigue siendo «¿Cómo voy?». Los tres mecanismos llaman a
`EnvironmentNarrationService.requestDescription()` (`NarrationRequesting`); el comando de voz
llega por `DestinationViewModel.narration`. La ayuda de voz menciona «Describe el entorno».

## Solicitudes repetidas (`NarrationRepeatPolicy`)

Solo para las pedidas por el usuario; las automáticas (SCRUM-40) no cambian.

1. **Una en curso**: no se envía otra y se dice «Ya estoy describiendo el entorno.» (P3).
2. **Otra vez en menos de 3 s** (el backend admite una cada 3 s): se repite la última
   descripción sin tomar foto ni llamar al backend.
3. **Otra vez en menos de 10 s con la misma escena**: se toma la foto, se compara su huella
   (`VNFeaturePrint`, mismo umbral 0,35 que SCRUM-40) y, si no cambió, se repite sin enviarla.
4. Pasados 10 s, o con otra escena, se describe de nuevo.

La repetición suena como «Sigue igual que hace un momento. …», entra como P3 (no interrumpe
alertas ni indicaciones) y vence igual que una descripción. Retirar el consentimiento borra la
última descripción: no se vuelve a decir.

## Criterios de aceptación

- Mecanismo accesible: botón, acción de VoiceOver y comando de voz.
- Captura al momento de la solicitud, procesamiento por el servicio de narración y resultado por
  audio: SCRUM-38.
- No interrumpe una alerta activa: la descripción y la repetición son P3.
- Informa si no puede procesar: avisos de SCRUM-38 y «Ya estoy describiendo el entorno.».
- Solicitudes repetidas sin procesamiento innecesario: reglas 1 a 3.

## Pruebas

`Tests/LumioFrontendTests/NarrationRequestTests.swift`.

## Validación en el iPhone

1. En «Tu ruta», abrir el menú de acciones de VoiceOver en la indicación y elegir «Describir entorno».
2. Con el comando de voz, decir «¿qué hay delante?»: se oye la descripción.
3. Pedirla dos veces seguidas: la segunda dice «Sigue igual que hace un momento…» sin esperar.
4. Girar hacia otro lado y pedirla otra vez: describe la nueva escena.
