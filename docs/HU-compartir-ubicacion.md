# HU: Compartir Ubicación (SCRUM-25)

Como usuario de Lumio, quiero compartir mi ubicación durante el trayecto para permitir que una
persona de confianza pueda conocer mi posición actual.

Etiqueta `post-mvp`. El registro de decisiones dejó fuera del MVP la ubicación en tiempo real con
push y las pantallas del acompañante; esta es una versión acotada que reutiliza lo que ya existe
para la emergencia (contactos de confianza y correo por SES). Backend: tulio3101/Lumio, módulo
`location_sharing`.

## Flujo

Preferencias > Emergencia > **Compartir ubicación** (`LocationSharingView` +
`LocationSharingService`):

1. Se explica qué se comparte y se elige cuánto tiempo (30 min, 1 h o 2 h).
2. «Compartir mi ubicación» pide **confirmación explícita** («¿Compartir tu ubicación con tus
   contactos de confianza durante 1 hora?»).
3. Sin red no se intenta. La ubicación sale de `CurrentLocationProviding` (la misma de la ruta):
   CoreLocation pide el permiso si falta; si está negado, se explica cómo concederlo.
4. `POST /location-shares` envía a cada contacto un correo con un **enlace privado** a una página
   con la última posición. Se dice «Estás compartiendo tu ubicación con 2 contactos hasta las
   3:30 p. m.» (y a cuántos no se pudo avisar).
5. Mientras se comparte, cada 30 s se envía la posición (`PUT …/position`). Un aviso fijo arriba de
   Trayecto («Compartiendo tu ubicación», con «Detener») lo recuerda.
6. **Sin conexión**: se dice una vez «Sin conexión: tu ubicación no se está actualizando…», el
   aviso cambia a «sin conexión» y se sigue intentando; al volver la red se dice y se retoma.
7. Termina con «Dejar de compartir» o «Detener» (`DELETE`, borra la posición en el backend), al
   vencer el tiempo (410) o al cerrar sesión (`SessionTeardown`). Si no hay red al detener, deja
   de enviar igual y avisa que el enlace vence solo.

Todo se dice por el AudioArbiter como P2 (contexto `location-sharing`): una alerta P1 lo
interrumpe.

## Privacidad

Solo se guarda la última posición, nunca un historial, y se borra al detener o vencer. El enlace
lleva un token aleatorio; el backend guarda solo su hash. La página no se guarda en caché, no se
indexa y no filtra el enlace al abrir el mapa.

## Pruebas

`Tests/LumioFrontendTests/LocationSharingTests.swift` (backend, GPS, red y audio falsos). Backend:
`tests/modules/location_sharing`.

## Validación en el iPhone

1. Con un contacto de confianza, compartir 30 min: llega el correo y la página muestra la posición.
2. Caminar un poco: la página se actualiza en menos de un minuto.
3. Activar el modo avión: se oye el aviso sin conexión; al quitarlo, el de reconexión.
4. «Detener» desde Trayecto: la página dice que ya no se comparte.
5. Repetir con VoiceOver: el aviso fijo y la confirmación se leen y se activan.
