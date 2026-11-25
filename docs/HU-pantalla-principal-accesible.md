# HU: Pantalla Principal Accesible

Como usuario con discapacidad visual, quiero una pantalla principal que pueda usar solo con
VoiceOver y gestos, para iniciar una ruta, activar la emergencia y abrir los ajustes sin
depender de la vista.

## Alcance

La pestaña Trayecto (DestinationView) es la pantalla principal. Es el punto de entrada de
Indicar Destino por Voz (SCRUM-313), Botón de Emergencia (SCRUM-35) y Consultar Ruta Actual
(SCRUM-23), y reemplaza las subtareas de interfaz de Crear, Modificar, Finalizar, Consultar y
Recalcular Ruta. Las pantallas visuales del acompañante quedan fuera del MVP.

Orden de VoiceOver (de arriba abajo):

1. «Lumio, trayecto» (encabezado).
2. «Estado de Lumio. …»: el mismo texto que se locuta al abrir; doble toque lo repite.
3. «Indicar destino por voz» (con ruta activa: «Cambiar destino por voz»), botón principal.
4. «¿Cómo voy?»: Consultar Ruta Actual.
5. «Ajustes»: cambia a la pestaña Preferencias.
6. La ruta activa o el estado sin ruta (como antes) y «Rutas recientes».
7. Botón de Emergencia, fijo abajo (EmergencyControl, SCRUM-35).
8. Botón «Comando de voz».

Se quitó la tarjeta «Próximamente», que anunciaba funciones que ya existen.

## Gestos y acciones rápidas

- Magic Tap (doble toque con dos dedos): dicta un destino. Si la escucha está abierta, la
  cierra. En la pantalla de la ruta (ActiveRouteView) el Magic Tap sigue repitiendo la
  indicación.
- Acciones del rotor en los elementos 2 a 5: «Indicar destino por voz» y «Emergencia».
- La emergencia no está en el Magic Tap a propósito: es fácil hacerlo sin querer. Igual tiene
  su margen para cancelar en el mismo botón.

## Dictar destino

`VoiceCommandService.startDestinationDictation()` pregunta «¿A dónde quieres ir?» sin el
«Te escucho» del comando general y sigue el mismo flujo que el comando «nueva ruta»: confirma
lo entendido y crea la ruta, o cambia el destino si hay una activa. Sin servicio de voz se abre
la búsqueda escrita. Cuando exista el dictado con geocodificación de SCRUM-313, se conecta en
este mismo punto.

## Estado al abrir

HomeStatusService arma el mensaje con datos locales (HomeAnnouncements.welcome) y lo locuta una
vez por apertura, como P2 (contexto `home-status`): una alerta crítica lo interrumpe.

- Sesión: «Sesión iniciada.» o, en el modo de desarrollo sin sesión, que las rutas no se guardan.
- Permisos esenciales (ubicación, micrófono, reconocimiento de voz): solo se nombran los negados,
  restringidos o desactivados, y se dice dónde concederlos. Los que no se han pedido se piden
  con el flujo accesible al usar la función; abrir la app no pide nada.
- Seguridad: «Detección de obstáculos lista: se activa al iniciar una ruta.» si el modelo está
  en la app y la cámara no está negada; si no, por qué no está disponible.
- Ruta activa guardada en el teléfono, si hay.
- Cómo usar las acciones rápidas.

No hay cambios de backend.

## Pruebas automatizadas

- HomeStatusTests: anuncio al abrir una sola vez y como P2; repetir a pedido; permisos negados
  nombrados y no pedidos omitidos; seguridad sin cámara o sin modelo; ruta activa y modo sin
  sesión; listas en español.
- VoiceCommandServiceTests: dictar destino pregunta directamente y crea la ruta.

Sin Swift/Xcode en el equipo de implementación: compilación y pruebas pendientes de CI.

## Validación en iPhone (con VoiceOver y la pantalla apagada con la cortina de pantalla)

1. Abrir la app: se oye el estado (sesión, permisos, detección) una vez.
2. Deslizar a la derecha: estado, «Indicar destino por voz», «¿Cómo voy?», «Ajustes»… hasta
   «Emergencia».
3. Magic Tap: pregunta «¿A dónde quieres ir?»; decir un lugar crea la ruta.
4. En «¿Cómo voy?», rotor de acciones: «Emergencia» inicia la cuenta para cancelar; doble
   toque en el botón de emergencia la cancela.
5. «Ajustes» abre Preferencias.
6. Negar la ubicación en Ajustes de iOS y abrir Lumio: el estado lo dice.
