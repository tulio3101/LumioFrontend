# HU: Interactuar con la Aplicación Mediante Voz

Como usuario de Lumio, quiero interactuar con la aplicación mediante comandos de voz para
ejecutar acciones sin depender de controles visuales.

## Alcance

Botón flotante «Comando de voz» (micrófono) en Trayecto y en Tu ruta. Activarlo abre el
micrófono para una sola frase; activarlo de nuevo cierra la escucha sin hacer nada.
Mientras escucha se muestra «Escuchando…» y el botón cambia a «Cerrar comando de voz».

El reconocimiento es local (SFSpeechRecognizer en español; en el iPhone si el dispositivo
lo permite) y la interpretación también: no hay backend ni red para entender comandos.
Los comandos reutilizan los casos de uso existentes; la voz no duplica lógica de navegación.

## Comandos

| Se puede decir | Acción | Caso de uso |
| --- | --- | --- |
| «Llévame a …», «Quiero ir a …», «Ruta a …» | Crear Ruta; con ruta activa, Modificar Ruta | SCRUM-8 / SCRUM-9 |
| «Nueva ruta», «Cambiar destino» | Pregunta «¿A dónde quieres ir?» y usa la respuesta | SCRUM-8 / SCRUM-9 |
| «Repetir instrucción», «Repite», «Otra vez» | Repetir la indicación actual | InstructionRepeating |
| «¿Cómo voy?», «¿Cuánto falta?», «¿Dónde estoy?» | Consultar Ruta Actual | SCRUM-23 |
| «Llegué» | Finalizar Ruta como completada (con confirmación) | Finalizar Ruta |
| «Terminar la ruta», «Cancelar ruta», «Detener navegación» | Finalizar Ruta sin llegar (con confirmación) | Finalizar Ruta |
| «Ayuda», «¿Qué puedo decir?» | Lee los comandos disponibles | Esta HU |
| «Nada», «Olvídalo» | Cierra la escucha | Esta HU |

Se comparan palabras sin tildes, mayúsculas ni puntuación; gana la frase más larga.
El destino conserva lo dicho («la Biblioteca Luis Ángel Arango»).

## Criterios de aceptación

- Activar la entrada por voz: botón accesible con etiqueta e indicación para VoiceOver.
  La primera vez se piden micrófono y reconocimiento de voz con el flujo accesible de
  SCRUM-315 (`PermissionsViewModel.requestForVoiceCommands()`): explica por audio y luego
  muestra el diálogo de iOS. Sin permisos, se explica cómo concederlos y no se abre el micrófono.
- Reconocer comandos soportados: `VoiceCommandInterpreter`, catálogo de la tabla.
- Ejecutar la acción: `DestinationViewModel` implementa `VoiceActionPerforming` con los
  mismos métodos que los botones.
- Aclarar ambigüedades: palabras sueltas como «ruta» o «cancelar» (con ruta activa) generan
  «¿Quieres … o …?». Se acepta la opción dicha o «la primera», «la segunda»… Sin ruta activa
  no se ofrecen acciones que la necesitan («cancelar» solo cierra la escucha).
- Informar comandos no reconocidos: «No reconocí el comando. Di ayuda…». Si no se oye nada,
  también se informa.
- Confirmar acciones: terminar la ruta («llegué» o «terminar») pide «sí» o «no» antes de
  ejecutarse; una respuesta dudosa conserva la ruta. Al pedir un destino se confirma lo
  entendido («Buscando una ruta a …»); el resultado lo anuncia Crear/Modificar Ruta.
  Los casos de uso que ya anuncian su resultado no se repiten.
- Sin interferir con alertas críticas:
  - Todo lo que dice la voz pasa por el AudioArbiter como P2 (contexto `voice-command`,
    vence a los 30 s): una alerta P1 siempre la interrumpe.
  - No se abre el micrófono si suena una alerta P1; se avisa que se intente al terminar.
  - Si empieza una P1 mientras se escucha, la escucha se corta, no se ejecuta nada y, después
    de la alerta, se avisa «Comando de voz interrumpido por una alerta».
  - El micrófono usa `.playAndRecord` con mezcla: no corta el audio que esté sonando.

## Fuera de alcance

«Estado de detección» y «Reintentar detección» dependen de SCRUM-37 (estado y reintento de
SafetyService). Se agregan al catálogo cuando SCRUM-37 esté en develop.
El dictado de destino con confirmación completa y geocodificación es SCRUM-313; esta HU
solo pasa el texto dicho a Crear/Modificar Ruta, que ya informa los errores.

## Pruebas automatizadas

- VoiceCommandInterpreterTests: comandos soportados, destino, frases más largas, ambigüedad,
  aclaración con candidatos y ordinales, no reconocido, sí/no.
- VoiceCommandServiceTests (escucha y audio falsos): ejecutar, confirmar destino, preguntar
  destino, aclaración, confirmación sí/no/dudosa, sin ruta, silencio, permisos denegados,
  alerta P1 antes y durante la escucha, audio no crítico, cerrar con el botón.

Sin Swift/Xcode en el equipo de implementación: compilación y pruebas pendientes de CI.

## Validación en iPhone

1. Activar «Comando de voz» la primera vez: explica y pide micrófono y reconocimiento de voz.
2. Sin ruta: «Llévame a [lugar cercano]» → confirma y crea la ruta.
3. Con ruta: «Repetir instrucción», «¿Cómo voy?», «Llévame a [otro lugar]» (cambia destino).
4. «Ruta» → pregunta; responder «la primera». «Cancelar» → pregunta; responder «dejar de escuchar».
5. «Terminar la ruta» → «no» conserva la ruta; repetir y decir «sí» la termina.
6. Decir algo sin sentido → informa que no lo reconoció.
7. Con VoiceOver activo, repetir 2 y 5 sin mirar la pantalla.
8. Durante una ruta con detección, provocar una alerta de obstáculo mientras escucha:
   la alerta suena completa y luego se avisa que el comando se interrumpió.
9. Modo avión: los comandos se reconocen si el iPhone admite reconocimiento local.
