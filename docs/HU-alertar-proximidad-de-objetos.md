# HU: Alertar Proximidad de Objetos (SCRUM-34)

Como usuario de Lumio, quiero recibir una alerta cuando un objeto se encuentre a una distancia
potencialmente peligrosa para reaccionar oportunamente.

Depende de la distancia por profundidad (SCRUM-320, ADR-307), del AudioArbiter (SCRUM-42) y de los
umbrales del spike SCRUM-309. Todo corre en el teléfono (ADR-306): no hay cambios en el backend.

## Qué había y qué cambia

La detección por objeto, el P1, la vibración, el silencio de objetos ya anunciados y el
funcionamiento sin red ya existían (SCRUM-33, SCRUM-37, SCRUM-42). Lo que no seguía el spike era la
**clasificación**: usaba un único umbral de 1 m, decía los metros en todo el rango y no distinguía el
modo reducido. Esta HU la reemplaza por `ProximityPolicy`.

## Tabla de umbrales (spike SCRUM-309 + ADR-307)

| Modo | Distancia | Nivel | Audio |
|---|---|---|---|
| LiDAR | ≤ 2,5 m (≤ 3,0 m si el objeto se acerca) | Zona de riesgo | **P1** «persona a 2,4 metros» |
| LiDAR | hasta 3,0 m, fuera de la zona de riesgo | Cerca, con metros | P3 «persona a 2,9 metros» |
| LiDAR | 3–4 m | Cerca, sin metros | P3 «persona cerca» |
| LiDAR | > 4 m | Lejos | P3 «persona a más de 4 metros» (ya existía, ver abajo) |
| LiDAR | sin distancia confiable | Sin proximidad | P3 «persona» |
| Sin LiDAR | < 1,5 m | Zona de riesgo | **P1** «persona muy cerca» |
| Sin LiDAR | 1,5–2,5 m | Cerca | P3 «persona cerca» |
| Sin LiDAR | > 2,5 m | Sin aviso de distancia | P3 «persona» |

- Los metros se dicen solo hasta 3 m con LiDAR y **nunca** en el modo reducido.
- Un objeto se considera en movimiento (3,0 m en lugar de 2,5 m) cuando el rastreador ve que su
  distancia baja (`TrackedDetection.isApproaching`).
- El riesgo para la trayectoria lo decide el pipeline: solo llegan al anunciador los objetos del
  corredor de marcha (`WalkingCorridor`). Los obstáculos por profundidad (paredes, mesas) usan la
  misma política con LiDAR y siempre como estáticos.
- Todos los umbrales viven en `DetectionFocusConfig.proximity`.

## Criterios de aceptación

- **Recibe la distancia de cada obstáculo (SCRUM-320):** `Detection.distanceMeters`.
- **Clasifica según el spike:** `ProximityPolicy.reading(distance:isApproaching:mode:)`.
- **Zona de riesgo = P1 del AudioArbiter:** `AudioMessage.priority == .immediateRisk`.
- **Audio y háptica:** el P1 suena, y vibra por `SafetyService` (`.warning`) y por el árbitro cuando
  empieza a sonar (`.criticalAlert`, `HapticPreferencesService.audioMessageChanged`).
- **Modo reducido:** `SafetyService` pasa `DepthMode.reduced` cuando el pipeline no tiene
  profundidad (`isDepthAvailable == false`); los avisos dicen «muy cerca» y «cerca», sin metros.
- **Sin conexión:** ningún paso usa red ni backend; `ProximityPolicy` y `ObstacleAnnouncer` son
  valores puros.
- **Sin alertas repetitivas:** cada objeto rastreado guarda el nivel más alto ya anunciado. Una
  distancia que oscila alrededor de un umbral no repite el aviso; solo vuelve a sonar si sube de
  nivel o si el objeto se sigue acercando y pasó el cooldown (4 s).

## Decisiones y diferencias que hay que revisar

1. **Más alertas P1.** La zona de riesgo pasa de 1 m a 2,5–3,0 m, como decidió el spike con las
   pruebas de campo. El usuario oirá alertas urgentes antes. Validar en la calle que no sean
   excesivas.
2. **«A más de 4 metros» se conserva.** El spike dice que más allá de ~4 m no hay *alerta de
   distancia*. El código ya anunciaba esos objetos como información P3 por una decisión posterior
   de `DepthSampler` (desvío de ADR-307); no es una alerta de proximidad y no se tocó. Si el
   equipo prefiere silencio, es un cambio de una línea en `ObstacleAnnouncer.audioText`.
3. **Umbral urgente del modo reducido: 1,5 m.** La tabla del spike y ADR-307 dicen «< 1,5 m»; el
   texto de justificación del spike menciona 1,2 m. Se usó 1,5 m (el valor de la tabla, el más
   conservador); `ProximityPolicy.reducedUrgentMeters` lo cambia.
4. **El modo reducido todavía no tiene fuente de distancia.** La cámara dual
   (`AVCapture` con profundidad, SCRUM-349) no existe en el código: sin LiDAR, `distanceMeters` es
   `nil` y los avisos solo nombran el objeto. La clasificación del modo reducido está
   implementada y probada, y funcionará cuando esa fuente entregue distancias, pero hoy no genera
   «muy cerca» ni «cerca» en un iPhone sin LiDAR.

## Pruebas

`Tests/SafetyTests/ProximityPolicyTests.swift` (tabla completa y sus bordes, modo reducido) y
`Tests/SafetyTests/ObstacleAnnouncerTests.swift` (P1 y vibración, 3 m si se acerca, «cerca» sin
metros entre 3 y 4 m, modo reducido, oscilación sin repetir y cooldown). Se actualizaron los casos
que asumían el umbral de 1 m.

Las pruebas no se pudieron ejecutar al escribirlas (sin toolchain de Swift en el equipo de
desarrollo): pendientes de CI en macOS.

## Validación en el iPhone

Con un iPhone con LiDAR, en un lugar controlado:

1. Acercarse a una silla quieta: «silla cerca» entre 3 y 4 m, con metros hasta 3 m y P1 a ≤ 2,5 m.
2. Caminar hacia una persona: el P1 debe sonar desde ~3 m y vibrar.
3. Quedarse quieto a ~2,5 m oscilando un poco: no debe repetir el aviso.
4. Modo avión: las alertas funcionan igual.
5. Con una narración sonando, acercarse a un obstáculo: el P1 la interrumpe.
6. Sin LiDAR (cuando exista la fuente dual de SCRUM-349): «muy cerca» y «cerca», nunca metros.
