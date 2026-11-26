# HU: Configurar Preferencias de Accesibilidad (SCRUM-32)

Como usuario de Lumio, quiero configurar mis preferencias de accesibilidad para adaptar la
interacción con la aplicación a mis necesidades.

Etiqueta `post-mvp`. Completa las preferencias de voz (SCRUM-27) y de vibración (SCRUM-28) con
el mismo esquema: se leen del teléfono, se aplican en memoria y nunca esperan al disco ni a la
red, así que no pueden retrasar una alerta de seguridad.

## Preferencias (Preferencias > Preferencias de accesibilidad)

| Preferencia | Predeterminado | Se aplica en |
| --- | --- | --- |
| Narración automática | Activada (ADR-308) | `AutoNarrationScheduler` (SCRUM-40): apagada, no toma fotos ni envía nada (`.skipped(.disabledByUser)`). «Describir entorno» a pedido sigue funcionando. |
| Decir el estado al abrir la app | Activado | `HomeStatusService.announceOnLaunch()`: apagado, no habla al abrir; «Estado de Lumio» a pedido sigue. |
| Avisos: Breves / Detallados | Detallados | `HomeAnnouncements.welcome`: con «Breves» se omiten las pistas de uso (cómo dictar el destino, dónde está la emergencia). |

## Comportamiento

- `AccessibilityPreferencesService` las lee al abrir la app de
  `FileAccessibilityPreferencesStore` (Application Support). Un archivo dañado se reemplaza por
  las predeterminadas y la pantalla lo avisa.
- Validación al leer: un campo que falta (versión anterior) o un valor desconocido (versión
  futura) toma su predeterminado sin perder los demás.
- Cada cambio se aplica al instante y se guarda; si no se puede guardar, se dice por audio
  (P2) y vale hasta cerrar la app.
- Eliminar Cuenta (SCRUM-7) vuelve a las predeterminadas.
- La pantalla usa `Toggle` y `Picker` nativos con pistas de VoiceOver.

## Fuera de alcance

No se respaldan en el backend (`/users/me/preferences` solo guarda voz y vibración): hacerlo
pide cambiar el contrato y una migración. El modelo ya está listo para sumarse a
`PreferencesSynchronizer` si el equipo lo decide.

## Pruebas

`Tests/LumioFrontendTests/AccessibilityPreferencesTests.swift`.
