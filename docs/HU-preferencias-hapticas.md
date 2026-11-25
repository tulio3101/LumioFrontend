# HU: Configurar Retroalimentación Háptica

Como usuario de Lumio, quiero configurar la retroalimentación háptica para adaptar las
alertas táctiles a mis preferencias.

## Alcance

Preferencias > Vibración (HapticPreferencesView):

- Interruptor «Vibración»: activa o desactiva la vibración de los eventos de la ruta.
- «Eventos»: un interruptor por evento configurable, con la descripción de su patrón.
- «Intensidad»: suave, media o fuerte.
- «Alertas de seguridad»: siempre activas, sin interruptor; «Probar alerta de seguridad».

Al encender un evento se siente su patrón y al cambiar la intensidad se siente un ejemplo:
confirma el cambio sin mirar la pantalla ni oír otra voz encima de VoiceOver.

## Eventos y patrones

| Evento (HapticCue) | Cuándo | Patrón | Configurable |
| --- | --- | --- | --- |
| routeReady | Ruta creada, destino cambiado o ruta recalculada | Dos toques cortos | Sí |
| routeFailed | No se pudo calcular la ruta | Un toque fuerte, pausa y uno suave | Sí |
| routeFinished | Finalizar Ruta (a mano o al llegar) | Tres toques que van subiendo | Sí |
| criticalAlert | Una alerta P1 del AudioArbiter empieza a sonar | Cuatro toques fuertes y rápidos | No |

Antes de esta HU, ruta lista y ruta terminada vibraban igual (éxito del sistema) y las
alertas de seguridad no vibraban. Ahora cada evento tiene un ritmo propio (HapticPattern) y
la intensidad multiplica la fuerza de cada toque. La alerta crítica no se escala.

## Diseño

```text
Settings/
  Domain/HapticPreferences.swift              Modelo, intensidad, patrones, contratos y textos
  Data/FileHapticPreferencesStore.swift        JSON en Application Support (junto a las de voz)
  Application/HapticPreferencesService.swift   Filtra cada evento, alertas críticas, guarda
  Presentation/HapticPreferencesView(Model)    Pantalla accesible
Navigation/Data/UIKitHapticFeedback.swift      Motor: pulsos con UIImpactFeedbackGenerator
```

- HapticPreferencesService es el HapticFeedbackPlaying que reciben Crear, Modificar,
  Recalcular y Finalizar Ruta. Esos servicios no cambian: siguen pidiendo `play(.routeReady)`
  y el servicio decide si vibra y con qué patrón, con las preferencias en memoria.
- Alertas críticas: AppDependencies conecta `AudioArbiterService.onMessageChanged` al servicio.
  Cuando un mensaje `immediateRisk` pasa a `playing`, vibra `criticalAlert` sin consultar las
  preferencias. Así cualquier productor de P1 (obstáculos, poca luz, detección) vibra sin
  tocar su código.
- Leer y aplicar nunca espera al disco ni a la red: el archivo se lee una vez al abrir la app.
- Eliminar Cuenta (SCRUM-7) borra el archivo y vuelve a las predeterminadas.
- No hay sincronización con el backend (no hay contrato de preferencias); cuando exista, debe
  ir después de aplicar y guardar en el teléfono, sin bloquear.

## Criterios de aceptación

- Activar o desactivar: interruptor «Vibración».
- Configurar las opciones definidas: eventos de la ruta e intensidad.
- Cada evento configurado genera su patrón: HapticPattern.pattern(for:intensity:), distinto
  por evento.
- Se leen del teléfono y no bloquean las alertas: FileHapticPreferencesStore al abrir; luego
  todo en memoria.
- Se conservan al cerrar la app: cada cambio se guarda en el JSON. Si no se pudo guardar, se
  aplica igual, se muestra y se locuta (P2) que al cerrar la app vuelve lo anterior.
- Las alertas críticas no cambian con las preferencias: siempre vibran con su patrón fuerte.
- Accesible con VoiceOver: interruptores y selector con etiqueta e indicación; cada evento
  describe su patrón y tiene la acción «Probar vibración» en el rotor.
- Sin motor de vibración (iPad): se avisa en la pantalla; las alertas siguen por audio.

## Pruebas automatizadas

HapticPreferencesTests (motor y almacenamiento falsos): lectura al abrir (guardado, sin
archivo, dañado); un patrón por evento y todos distintos; intensidad y alertas críticas sin
escalar; desactivar todo o un evento; probar un evento apagado; sin cambios; fallo al guardar;
alertas críticas con la vibración apagada y desde el árbitro real (solo P1, una vez);
persistencia real entre dos instancias; resumen; Eliminar Cuenta.

Sin Swift/Xcode en el equipo de implementación: compilación y pruebas pendientes de CI.

## Validación en iPhone

1. Preferencias > Vibración con VoiceOver: se lee el resumen y cada evento con su patrón.
2. Crear una ruta: dos toques. Finalizarla: tres toques que suben. Distinguirlos sin audio.
3. Desactivar «Vibración» y crear una ruta: no vibra. Provocar una alerta de obstáculo: vibra.
4. Apagar solo «Ruta lista»: crear ruta no vibra; finalizarla sí.
5. Intensidad suave y fuerte: se nota la diferencia en los eventos, no en la alerta crítica.
6. Cerrar la app por completo y abrirla: se conservan.
7. Con «Hápticos del sistema» apagado en Ajustes de iOS no vibra nada: es del sistema.
