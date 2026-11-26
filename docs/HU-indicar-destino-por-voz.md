# HU: Indicar Destino por Voz (SCRUM-313)

Como usuario con discapacidad visual, quiero indicar mi destino hablando para iniciar una
ruta sin escribir ni mirar la pantalla.

## Cómo se activa

Las mismas entradas de la HU Interactuar mediante voz: Magic Tap o «Indicar destino por voz»
en Trayecto (pregunta «¿A dónde quieres ir?»), el botón «Comando de voz» con «llévame a …»,
«quiero ir a …» o «nueva ruta». La transcripción es local, en español (`DeviceSpeechListener`).

## Flujo

`VoiceCommandService.dictate` con `MapKitDestinationLookup` (MKLocalSearch cerca del usuario,
radio 20 km, hasta 3 lugares con calle y ciudad):

1. **Un lugar**: «Entendí Biblioteca Luis Ángel Arango, Calle 11 4-14, Bogotá. ¿Quieres ir
   ahí? Di sí o no.» Con «sí» se calcula la ruta con `DestinationRequest.place` (ya
   geocodificado, Crear Ruta no vuelve a buscar). Con «no», «Dime el destino de nuevo.»
2. **Varios lugares**: «Encontré 2 lugares para parque. Uno: … Dos: … ¿Cuál quieres? Di el
   número o di ninguno.» Se acepta el número («la segunda», «dos») o el nombre («el Tunal»).
   Elegir ya es la confirmación. «Ninguno» pide el destino otra vez; una respuesta que no
   distingue una opción («parque») se trata como no entendida.
3. **No encontrado**: «No encontré …» y se pide de nuevo.
4. **Sin red o sin ubicación** (`.unavailable`): no se puede comprobar el lugar; se lee lo
   entendido y se pide sí/no. Con «sí» se envía el texto (`.query`) y Crear Ruta informa por
   audio si tampoco puede.
5. Se pide el destino **dos veces como máximo**. Al agotar los intentos: «No busqué ninguna
   ruta. Puedes intentarlo de nuevo con otro nombre o una dirección.»
6. Con ruta activa el destino confirmado va a Modificar Ruta («Cambiando el destino a …»).
   Crear y Modificar Ruta anuncian el resultado; la voz no lo repite.

Sin micrófono o sin permiso de reconocimiento, el flujo accesible de SCRUM-315 lo explica por
audio y dice cómo concederlo en Preferencias, Permisos. Todo lo que se dice va por el
AudioArbiter como P2 (contexto `voice-command`): una alerta P1 lo interrumpe y corta la escucha.

## Contratos

- `DestinationLookingUp.lookUp(_:) -> DestinationLookup` (`.found([SpokenPlace])`,
  `.notFound`, `.unavailable`). Sin `lookup`, `VoiceCommandService` mantiene el comportamiento
  anterior (texto directo a Crear Ruta).
- `VoiceActionPerforming.navigate(to: DestinationRequest)`: lo implementa `DestinationViewModel`.
- Reglas y textos en `DestinationDictationPolicy`; elección con
  `VoiceCommandInterpreter.destinationChoice(in:options:)`.

## Pruebas

`Tests/LumioFrontendTests/DestinationDictationTests.swift` (escucha, búsqueda y audio falsos).

## Validación en iPhone

1. Magic Tap en Trayecto, decir un lugar conocido cercano: lo lee con su dirección; «sí» crea la ruta.
2. Decir «parque»: lee hasta tres opciones; elegir «la segunda».
3. Decir algo que no existe dos veces: lo informa y no crea ruta.
4. Con ruta activa, «llévame a [otro lugar]» → confirma y cambia el destino.
5. Modo avión: pide confirmar el texto; al aceptar, Crear Ruta informa que no hay conexión.
6. Repetir 1 y 2 con VoiceOver activo y sin mirar la pantalla.
