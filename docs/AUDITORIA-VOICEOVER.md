# Auditoría de accesibilidad con VoiceOver (SCRUM-29)

Revisión del código de las 30 vistas SwiftUI de `Sources/LumioFrontend` contra los criterios
de la HU, con foco en los flujos principales: cuenta, destino por voz, ruta y emergencia.
La parte de código está hecha; la prueba completa con VoiceOver en un iPhone queda pendiente
(lista al final).

## Método

1. Controles sin nombre: botones cuyo contenido es solo un icono, `onTapGesture` /
   `onLongPressGesture` (no son botones para VoiceOver) e imágenes sin
   `accessibilityLabel` ni `accessibilityHidden`.
2. Estados dinámicos: botones que muestran un `ProgressView` mientras trabajan, avisos que
   cambian y mensajes de estado.
3. Errores: si el error de un campo se oye al llegar al campo, no solo como texto aparte.
4. Orden y agrupación: textos que se leen como muchos elementos sueltos.

## Lo que ya cumplía

- No hay `onTapGesture` ni `onLongPressGesture`: toda acción es un `Button`.
- Todos los botones con solo icono tienen etiqueta: micrófono («Comando de voz» / «Cerrar
  comando de voz», con `isSelected` mientras escucha), «Mostrar/Ocultar contraseña»,
  «Borrar destino», botón de emergencia (cambia de etiqueta y pista sin perder el foco).
- Los iconos decorativos (`LumioIconBadge`, `LumioMark`, separadores, bandera de llegada)
  están ocultos para VoiceOver.
- Avisos de estado (`LumioStatusBanner`, recálculo, carga de rutas recientes, cálculo de la
  ruta) se leen como un solo elemento; el cálculo de ruta usa `updatesFrequently`.
- Los errores de Mi cuenta, Contactos de confianza y Recuperar contraseña van en la pista del
  propio campo.
- Acciones de VoiceOver: Magic Tap («¿Cómo voy?» en ruta, dictar destino en Trayecto) y menú
  de acciones en la indicación actual («Consultar ruta», «Recalcular ruta», «Finalizar ruta»,
  «Describir entorno»); «Indicar destino por voz» y «Emergencia» en Trayecto.
- Todo resultado importante se dice además por el AudioArbiter, no solo en pantalla.

## Hallazgos corregidos

| # | Flujo | Problema | Corrección |
| --- | --- | --- | --- |
| 1 | Cuenta (crear / iniciar sesión) | El error del correo o la contraseña era un texto aparte debajo del campo: VoiceOver leía el campo sin decir qué estaba mal. | `AccountFormView.LabeledInput` pone «Error: …» (o la ayuda) en la pista del campo, como en Mi cuenta. |
| 2 | Ruta | Mientras recalcula, «Recalcular ruta» seguía diciendo «Recalcular ruta» (atenuado). | Etiqueta «Recalculando la ruta» mientras dura. |
| 3 | Ruta | Mientras finaliza, «Finalizar ruta» no decía que estaba trabajando. | Etiqueta «Finalizando la ruta». |
| 4 | Preferencias | «Cerrar sesión» con el indicador de progreso no anunciaba el cambio. | Etiqueta «Cerrando sesión». |
| 5 | Permisos | Cada permiso se leía en 3 o 4 elementos sueltos (nombre, estado, propósito, nota) antes de llegar a los botones. | Nombre, estado y propósito forman un solo elemento con rasgo de encabezado; «Último mensaje» se marca `updatesFrequently`. |

## Pendiente: prueba en iPhone con VoiceOver

Con VoiceOver activo y sin mirar la pantalla (cortina de pantalla: tres toques con tres dedos):

1. **Cuenta**: crear una cuenta con un correo inválido; el campo debe decir «Error: Escribe un
   correo válido…». Iniciar sesión.
2. **Permisos**: recorrer Preferencias > Permisos; cada permiso se lee de una vez y luego sus
   botones.
3. **Destino por voz**: Magic Tap en Trayecto, dictar un lugar, confirmar con «sí».
4. **Ruta**: en «Tu ruta», menú de acciones de la indicación: «Consultar ruta», «Recalcular
   ruta» (debe oírse «Recalculando la ruta»), «Describir entorno», «Finalizar ruta».
5. **Emergencia**: activar con doble toque, oír la cuenta atrás y cancelar con otro doble toque
   en el mismo lugar.
6. **Orden**: en cada pantalla, deslizar de principio a fin; el orden debe seguir el visual y
   ningún control debe quedar sin nombre («botón» a secas).
7. Anotar aquí cualquier hallazgo nuevo con su pantalla y el texto que lee VoiceOver.

Con esos pasos verificados, se cumplen los criterios «flujos principales solo con VoiceOver» y
«la navegación no requiere identificar visualmente los controles».
