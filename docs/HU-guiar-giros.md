# HU: Guiar Giros durante el Trayecto (SCRUM-312)

Como usuario con discapacidad visual, quiero recibir cada giro de mi ruta en el momento
correcto por audio y vibración para seguir el camino sin mirar la pantalla.

Épica: Navegación y Rutas (SCRUM-13). Depende de AudioArbiter (SCRUM-42), Crear Ruta
(SCRUM-8) y las reglas de audio del spike SCRUM-309 (implementadas en SCRUM-44).

## Qué oye y siente el usuario

Para cada giro de la ruta activa, dos anuncios por el AudioArbiter (P2):

| Momento | Ejemplo | Vibración |
| --- | --- | --- |
| Aviso previo (unos 25 s antes, entre 30 y 60 m) | «En 40 metros, gira a la izquierda en la Calle 26.» | Lado del giro |
| Ahora (unos 6 s antes, entre 8 y 15 m) | «Ahora, gira a la izquierda en la Calle 26 y continúa 150 metros.» | Lado del giro |
| Antes de llegar | «En 30 metros, llegas a Biblioteca Nacional. El destino está a la derecha.» | — |
| Al llegar (Finalizar Ruta, SCRUM-10) | «Llegaste a Biblioteca Nacional. La navegación terminó.» | Ruta terminada |

- Izquierda: dos toques lentos (`HapticCue.turnLeft`). Derecha: tres toques rápidos
  (`HapticCue.turnRight`). Seguir recto o una instrucción sin lado no vibra. Ambos eventos se
  pueden apagar en Preferencias > Vibración y respetan la intensidad elegida.
- Si la primera lectura ya está cerca del giro, solo suena «Ahora».
- La primera indicación (la del punto de partida) no se repite: ya la dijo «Ruta lista»,
  «Ruta actualizada» o «Ruta recalculada».
- Si se pierde la red: «Sin conexión a internet. La guía de giros sigue con la ruta guardada
  en el teléfono y la detección de obstáculos sigue activa.» Al volver: «Volvió la conexión a
  internet.»
- Si la señal de GPS se degrada (3 lecturas seguidas con precisión peor que 25 m o 15 s sin
  lecturas): «Señal de GPS débil. Las indicaciones de giro pueden llegar tarde; avanza con
  precaución. La detección de obstáculos sigue activa.» Tras 2 lecturas precisas: «Señal de
  GPS recuperada. Sigue la guía de giros.»

## Diseño

```text
Navigation/
  Domain/TurnGuidance.swift                     Lado y geometría (TurnManeuver), cuándo anunciar
                                                (TurnGuidancePolicy) y textos (TurnAnnouncements)
  Application/TurnGuidanceMonitor.swift         Sigue el GPS, avanza currentStep, entrega anuncios
                                                y vibración, avisa de GPS y red
  Application/SharedLocationTracker.swift       Observadores de la fuente de GPS compartida
  Data/CoreLocationRouteTracker.swift           Entrega también la velocidad (LocationFix)
Settings/Domain/HapticPreferences.swift         Eventos turnLeft y turnRight con sus patrones
```

1. **Seguimiento (SCRUM-325).** `TurnGuidanceMonitor` es un observador de
   `SharedLocationTracker`: recibe las mismas lecturas que la llegada y la desviación mientras
   alguna las mantiene encendidas, es decir, mientras hay ruta activa (también con el teléfono
   bloqueado). No hace falta tocar `RootView` ni el ViewModel. Lee la ruta solo de la copia
   local (`ActiveRouteStoring`): el backend no interviene y sin red la guía sigue igual.
2. **Dónde está el usuario.** `RouteProgressEstimator` proyecta la lectura sobre la ruta y
   dice qué maniobra viene y a cuántos metros. `currentStep` avanza en la copia local, solo
   hacia delante, para que «Repetir indicación» y Consultar Ruta (SCRUM-23) usen el paso real.
   Las lecturas con precisión peor que 25 m no anuncian ni avanzan. A más de 30 m del
   trayecto no se anuncian giros: decide Recalcular Ruta (SCRUM-26). A menos de 25 m del
   destino decide la llegada (SCRUM-127).
3. **Cuándo anunciar (SCRUM-326).** `TurnGuidancePolicy` usa la velocidad del GPS (entre 0,2
   y 3 m/s; si no, la marcha típica de 1 m/s): aviso previo a `velocidad × 25 s` (30–60 m) y
   «Ahora» a `velocidad × 6 s` (8–15 m), lo que tarda la frase más el margen de reacción del
   spike (1,5 s cerrado, 2,5 s amplio). Cada anuncio se entrega una vez por giro y revisión.
4. **AudioArbiter y háptica (SCRUM-327).** Cada anuncio es P2 con
   `TurnDeadline(distanceMeters:speedMetersPerSecond:geometry:now:)`: si suena una narración,
   el árbitro hace esperar al giro salvo que esperar deje menos del margen de reacción; entonces
   la corta (SCRUM-44). Una alerta P1 siempre pasa delante. La geometría sale de la
   instrucción: «ligeramente», «mantente» o «curva» es un giro amplio; lo demás, cerrado.
   - «Ahora» va en el contexto de la revisión (`NavigationInstructionBuilder.contextID`), con
     clave `turn-<paso>-now`, y vence 3 s después del momento estimado del giro.
   - El aviso previo va en un contexto propio del giro (`<contexto>-turn-<paso>`). Al tocar
     «Ahora», al pasar el giro, al cambiar la revisión o al terminar la ruta se corta con
     `cancel(contextIDs:)`: el árbitro atiende los P2 en orden de llegada y, si no, sonaría
     «En 25 metros…» con el giro encima.
   - La vibración se pide a `HapticFeedbackPlaying` (HapticPreferencesService), que aplica las
     preferencias.
5. **Llegada, GPS y red (SCRUM-328).** La última maniobra se anuncia una vez antes de llegar;
   «Llegaste a…» lo dice Finalizar Ruta cuando `ArrivalMonitor` confirma la llegada. La red se
   comprueba con `ConnectivityObserving` en cada lectura y cada 5 s, y la señal de GPS con el
   mismo temporizador. Estos avisos van en el contexto de la revisión (se cortan con la ruta).
   Nada de esto toca la detección de obstáculos: es local y no depende de la red ni del GPS.

Backend (`tulio3101/Lumio`): `PUT /users/me/preferences` acepta `turnLeft` y `turnRight` en
`haptic_disabled_events`, para respaldar esos eventos como los demás.

## Criterios de aceptación

| Criterio | Dónde |
| --- | --- |
| Sigue la posición durante la ruta activa mediante GPS | `SharedLocationTracker` → `TurnGuidanceMonitor.receive` |
| Usa la copia local y no depende del backend | Solo `ActiveRouteStoring`; sin red se sigue guiando |
| Anuncia cada giro con anticipación, dirección y distancia | `TurnGuidancePolicy.stage`, `TurnAnnouncements.prepare/now` |
| Mensaje de navegación P2 por el AudioArbiter | `AudioMessage(priority: .routeInformation, turnDeadline:)` |
| Patrón háptico distinto para izquierda y derecha | `HapticCue.turnLeft` / `.turnRight`, `HapticPattern` |
| Espera a la locución en curso salvo urgencia (SCRUM-309) | `TurnDeadline` + `AudioPolicy.shouldInterrupt` |
| Anuncia la llegada | Aviso previo `approaching` + «Llegaste a…» de Finalizar Ruta |
| Informa pérdida de red o GPS degradado sin afectar a la detección | `TurnAnnouncements.offline/gpsWeak` |

## Pruebas

`Tests/LumioFrontendTests/TurnGuidanceTests.swift` (swift-testing, sin hardware): lado y
geometría de la instrucción, patrones distintos, distancias según la velocidad, aviso previo
y «Ahora» con dirección, distancia, P2, `TurnDeadline` y vibración, avance de `currentStep`
sin retroceder, la primera indicación no se repite, llegada, fuera de ruta, lecturas
imprecisas, nueva revisión, espera y corte de una narración con el árbitro real, GPS débil y
recuperado, red perdida y recuperada, y vida ligada a la fuente de GPS compartida.

Pendiente en dispositivo (SCRUM-329): caminar una ruta real para validar las distancias, la
velocidad típica y los textos de MapKit en español.
