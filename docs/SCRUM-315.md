# SCRUM-315: permisos accesibles

## Alcance

Pantalla en Trayecto > Preparar permisos y Preferencias > Permisos y accesibilidad.
No solicita permisos al arrancar la app. Cada solicitud tiene explicación, Continuar
(expresa consentimiento para abrir el diálogo nativo) y Ahora no. Sin VoiceOver se
reproduce la explicación mediante AudioArbiter antes de habilitar Continuar.
Con VoiceOver se enfoca el texto explicativo y se conserva la navegación nativa;
Repetir explicación solicita una locución al árbitro. No hay otro sintetizador.

Los mensajes de preparación se clasifican como P2 no urgente: no interrumpen P1
ni narración en curso. P1 puede interrumpirlos; P2 se reinicia según la política actual.
Cerrar la explicación cancela su locución pendiente o activa sin vaciar la cola global.

## Política implementada

- Dictado: micrófono, después reconocimiento de voz. No activa captura ni transcripción:
  SCRUM-313 deberá consultar `PermissionService.missing(for: .voiceDestination)` antes
  de iniciar y al volver de Ajustes, y detener la captura ante revocación.
- Cálculo de ruta: ubicación mientras se usa la aplicación. El botón actual consulta
  el permiso sin solicitarlo automáticamente; indica por audio y texto si falta.
- Obstáculos: cámara. `missing(for: .obstacleAssistance)` queda disponible para Safety.
- Notificaciones: adaptador disponible, sin solicitud en la interfaz actual, porque
  ninguna función conectada las necesita. No bloquean rutas.
- Autorizaciones se consultan a iOS, sin persistir copias como fuente de verdad.
- Denegado: explicar limitación y ofrecer Ajustes. Restringido: explicar restricciones
  del dispositivo sin prometer que la app pueda eliminarlas. Ubicación desactivada:
  informar sobre Localización en Privacidad y seguridad.

## Decisiones pendientes del equipo

Cámara necesaria para iniciar un trayecto asistido completo frente a cálculo de ruta;
política de segundo plano y precisión reducida de ubicación; función concreta de
notificaciones. No se solicita Always ni se configura segundo plano sin ese alcance.
No se afirma que conceder permisos implique que sensores o navegación estén listos.

## Verificación automática

`swift test` prueba estados, revocación, requisitos y espera/cancelación/interrupción
P1 de explicaciones. El workflow permissions-validation ejecuta pruebas portables en
macOS y pruebas iOS en simulador. No sustituye sensores y VoiceOver en dispositivo.

En el equipo Windows de implementación no hay Swift/Xcode instalado: las pruebas
se añadieron, pero no se ejecutaron localmente. No se realizó push ni ejecución remota.
Se añadió la rama HU-Solicitar-Permisos-de-Forma-Accesible a los filtros del workflow
de distribución para que también pueda generar el IPA al hacer push. El workflow
permissions-validation ejecuta las pruebas por separado.

## Recorrido manual en iPhone

Registrar modelo, versión exacta de iOS, rama y commit. Usar un entorno controlado,
sin iniciar un trayecto real para probar estos diálogos.

1. Abrir Preferencias > Permisos y accesibilidad con VoiceOver activado.
2. Recorrer controles sin mirar: títulos, estados, explicación y acciones.
3. Configurar micrófono: escuchar o leer explicación, continuar y denegar en iOS.
   Verificar feedback de limitación, Abrir Ajustes y ausencia de nueva solicitud.
4. Habilitar micrófono en Ajustes y volver. Verificar estado actualizado y anuncio.
5. Configurar reconocimiento de voz. Con permisos nuevos, verificar que se ofrece
   micrófono primero y después reconocimiento, sin diálogos simultáneos.
6. Repetir aceptar/denegar para cámara y ubicación. Revocar en Ajustes y regresar.
7. Desactivar Localización globalmente. Debe indicarse servicio no disponible.
8. Intentar Calcular ruta con un destino y sin ubicación: debe explicar qué falta.
   Con permiso, continúa al servicio provisional; no debe inventar una ruta válida.
9. Repetir con VoiceOver apagado: esperar el audio antes del diálogo; cancelar y
   repetir explicación. Comprobar volumen, Bluetooth y cancelación de la pantalla.
10. Verificar que notificaciones no solicita autorización ni bloquea cálculo de ruta.
11. Probar texto grande, restricciones de Tiempo de uso, regreso desde segundo plano,
    interrupciones por llamadas/Siri y convivencia de TTS con VoiceOver. Registrar
    fallos; estas condiciones no se consideran validadas por pruebas simuladas.

El cierre de la HU requiere compilación iOS exitosa y evidencia de estas pruebas.

## Regresión: Configurar no abre la explicación

Se aplica estilo borderless a los botones de la lista para aislar sus acciones. El
estilo automático de List puede activar varios botones de la misma fila: Escuchar
estado inicia la voz y el guard de Configurar impide entonces abrir la explicación.
Esta es una causa probable identificada al revisar el código; falta confirmar en
dispositivo que explica el fallo reportado.

Con un IPA del commit corregido y micrófono Sin solicitar:

1. Pulsar únicamente Configurar micrófono: debe abrir Antes de continuar, sin
   reproducir el mensaje de Escuchar estado.
2. Pulsar Ahora no y después Escuchar estado: debe reproducir el estado sin abrir
   la explicación ni solicitar autorización.
3. Repetir ambos pasos con VoiceOver y doble toque sobre cada control.
4. Confirmar que Continuar con Micrófono permanece visible y se habilita al
   finalizar la explicación.
