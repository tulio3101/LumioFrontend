# HU: Configurar Preferencias de Voz Descriptiva

Como usuario de Lumio, quiero configurar las preferencias de la voz para adaptar las
locuciones de la app a mis necesidades.

## Alcance

Preferencias > Preferencias de voz (VoicePreferencesView). Se elige el idioma (variante de
español), la voz y la velocidad. Cada cambio se aplica en el acto a todo lo que dice Lumio
y se confirma por audio con la configuración nueva. «Probar la voz» dice una frase de ejemplo.

Solo variantes de español: todos los textos de Lumio están en español y una voz de otro
idioma los leería mal. Las variantes y voces que se ofrecen son las instaladas en el teléfono
(AVSpeechSynthesisVoice); las mejoradas aparecen con «(mejorada)» si el usuario las descargó.

La velocidad va de 0,5 a 2 veces la normal, en pasos de 0,25. Se multiplica la velocidad
normal del sistema (AVSpeechUtteranceDefaultSpeechRate) sin salirse de sus límites.

## Diseño

```text
Settings/
  Domain/VoicePreferences.swift            Modelo, contratos, validación, velocidad y textos
  Data/FileVoicePreferencesStore.swift      JSON en Application Support (junto a la ruta activa)
  Data/SystemVoiceCatalog.swift             Voces en español instaladas (AVFoundation)
  Application/VoicePreferencesService.swift Leer, validar, aplicar, guardar y locutar
  Presentation/VoicePreferencesView(Model)  Pantalla accesible
Audio/Data/SpeechAudioPlayer.swift          Aplica idioma, voz y velocidad a cada utterance
```

- AppDependencies crea VoicePreferencesService justo después del reproductor y del árbitro,
  antes que cualquier productor de audio. El servicio lee el archivo y aplica las
  preferencias al reproductor en su init: la primera locución de la app ya sale con ellas.
- El reproductor guarda las preferencias en memoria. Reproducir nunca lee el disco ni
  espera a la red, así que una alerta P1 no se retrasa. Un cambio vale desde la siguiente
  locución; la que está sonando termina como empezó.
- Lo que dice el servicio pasa por el árbitro como P2 (contexto `voice-preferences`, vence a
  los 30 s). Cada mensaje nuevo cancela el anterior del mismo contexto: al subir la velocidad
  varias veces seguidas solo se oye la última confirmación. Una alerta P1 lo interrumpe.
- Eliminar Cuenta (SCRUM-7) borra el archivo y vuelve a la voz predeterminada. Cerrar sesión
  no las borra: son del teléfono.

## Criterios de aceptación

- Consultar las preferencias actuales: la pantalla abre con un resumen («Idioma: Español
  (México). Voz: predeterminada. Velocidad: normal.») que VoiceOver lee como un solo elemento,
  y cada control muestra su valor.
- Seleccionar el idioma disponible: selector con las variantes de español instaladas.
  Cambiar de idioma usa la voz predeterminada de ese idioma (las voces son por idioma).
- Seleccionar la voz disponible: «Predeterminada» y las voces instaladas del idioma elegido.
- Modificar la velocidad: control ajustable (VoiceOver: deslizar arriba o abajo) que dice su
  valor («1,25 veces») y «Volver a la velocidad normal».
- Se aplican a todas las locuciones del AudioArbiter: el ajuste está en SpeechAudioPlayer, el
  único reproductor del árbitro. Seguridad, navegación, narración, comandos de voz y los
  mensajes de cuenta usan la misma configuración.
- Se leen siempre del teléfono: FileVoicePreferencesStore es la única fuente. No hay
  sincronización con el backend en esta HU (no hay contrato de preferencias en el backend).
  Cuando exista, debe ir después de aplicar y guardar en el teléfono, sin bloquear.
- Se conservan al cerrar y abrir la app: cada cambio aplicado se guarda en el JSON.
- Informar cuando una configuración no se puede aplicar (se locuta y se muestra en un aviso):
  - Velocidad fuera de 0,5–2, idioma no disponible o voz no instalada: no se cambia nada.
    Para una voz no instalada se indica dónde descargarla.
  - No se pudo guardar: el cambio se aplica, pero se avisa que al cerrar la app vuelve la
    configuración anterior.
  - Al abrir la app, lo guardado que ya no se puede usar (voz desinstalada, idioma ausente,
    velocidad inválida o archivo dañado) se reemplaza por lo predeterminado sin perder lo
    demás, y se explica en la pantalla de Preferencias de voz. El archivo no se reescribe.
- Accesible con VoiceOver: etiquetas, valores e indicaciones en cada control; los avisos no
  mueven el foco para no superponer VoiceOver con la voz de Lumio.

## Pruebas automatizadas

VoicePreferencesTests (catálogo, almacenamiento y reproductor falsos):
- Al abrir: aplica lo guardado sin locutar; sin archivo usa lo predeterminado; archivo dañado,
  voz desinstalada, idioma ausente y velocidad inválida se ajustan y se informan.
- Cambiar velocidad, idioma y voz: aplica, guarda y confirma con la voz nueva; sin cambios no
  hace nada; cada confirmación reemplaza a la anterior; «Probar la voz».
- Rechazos: velocidad inválida, voz no instalada e idioma no disponible no cambian nada.
- Fallo al guardar: se aplica y se avisa.
- Persistencia real con FileVoicePreferencesStore entre dos instancias (cerrar y abrir).
- Árbitro real: P1, P2 y P3 suenan con las preferencias elegidas; una P1 interrumpe la
  confirmación.
- Velocidad del sistema, nombres con coma decimal y nombres de idioma.
- Eliminar Cuenta borra las preferencias; si falla, se conservan.

Sin Swift/Xcode en el equipo de implementación: compilación y pruebas pendientes de CI.

## Validación en iPhone

1. Preferencias > Preferencias de voz con VoiceOver: se lee el resumen actual.
2. Cambiar la velocidad a 1,5: la confirmación ya suena más rápida. Iniciar una ruta: las
   indicaciones y las alertas de obstáculo suenan a 1,5.
3. Elegir Español (España) y una voz: la confirmación usa esa voz.
4. Cerrar la app por completo y abrirla: se conservan.
5. Descargar una voz mejorada en Ajustes, elegirla, borrarla en Ajustes y abrir Lumio: se
   usa la predeterminada del idioma y la pantalla lo explica.
6. Durante una ruta con detección, cambiar la velocidad mientras suena una alerta: la alerta
   no se corta ni se retrasa; la siguiente locución usa la velocidad nueva.
