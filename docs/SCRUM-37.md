# SCRUM-37: manejo de errores del modelo

## Base integrada

Se integró sobre develop (b13bbbc), que ya incluye la detección de SCRUM-33 rediseñada
(rastreo, corredor, obstáculos por profundidad, poca luz e inclinación). El trabajo
original de esta HU se escribió sobre la versión anterior del pipeline (f69930a); se
re-implementó dentro del pipeline nuevo sin cambiar sus reglas de detección. Se usa el
punto de extensión que develop dejó en AppDependencies y SafetyAudio.

La detección sigue arrancando y deteniéndose con la ruta activa (DestinationViewModel)
y la compuerta de cámara de SCRUM-315. Esta HU no cambia ese ciclo de vida.

## Política de fallos y recuperación

- SafetyService siempre existe. La carga de Core ML y la inferencia viven en un
  actor dedicado (RecoveringModel), no en el hilo principal ni en AppDependencies.
  El modelo se prepara al iniciar la detección, antes de abrir la cámara.
- Se distinguen modelo ausente, carga fallida, inferencia fallida y salida incompatible.
- Una lista vacía válida significa que no se detectaron objetos. Una excepción o un
  tipo de resultado incompatible no se convierten en una lista vacía.
- Carga/inferencia recuperables: hasta tres reconstrucciones locales, a 1, 2 y 4 s.
  Carga e inferencia comparten presupuesto. Reconstruir el modelo no lo reinicia;
  solo una inferencia válida lo reinicia y confirma la recuperación.
- Modelo ausente y salida incompatible: sin reintentos automáticos. No se pueden
  reparar descargando nada; pueden requerir una nueva compilación o modelo corregido.
- El frame fallido se descarta. La siguiente inferencia usa un frame nuevo.
- Agotado el presupuesto, se informa no disponible y se ofrece Reintentar detección
  (pantalla de inicio, sección de la ruta activa). El reintento manual o una nueva
  ruta inicia un presupuesto nuevo. Sin ruta activa el reintento no enciende la cámara.
- Falta de profundidad mantiene detección sin distancias. No se activa automáticamente
  cámara dual como recuperación de un fallo de modelo: ADR-307 no define ese cambio.
- Fallos y fin inesperado de cámara se notifican como captura no disponible. Se puede
  reintentar manualmente o al regresar a primer plano. Las interrupciones de ARKit
  finalizan el flujo actual; una sesión nueva construye flujos nuevos.
- No hay HTTP, descarga del modelo ni chequeos de conectividad en el circuito local.

## Estado y audio

Estado visible en Debug y Release (SafetyStatusView, durante la ruta): detenido,
preparando, activo, recuperando o no disponible. Nunca se anuncia activo únicamente por
haber cargado el modelo; el modo completo/reducido se anuncia con la primera inferencia
válida. Un episodio de fallo genera un único aviso P1 (SafetyAudio.modelUnavailable);
los intentos no lo repiten. La recuperación confirmada genera un aviso P2 con vencimiento
(SafetyAudio.detectionRecovered). Durante la recuperación no se emiten avisos de obstáculos.

Todo el audio de seguridad usa el contexto "safety". Detener o perder la detección
cancela solo ese contexto (cancel(contextIDs:)); no llama a resetSession y conserva
navegación y narración. Los servicios de navegación no se recrean por un fallo del detector.

## Pruebas automatizadas

ModelRecoveryTests: modelo ausente, carga transitoria, presupuesto de fallos de
inferencia, salida incompatible, escena vacía válida, descarte del frame fallido,
reinicio del presupuesto tras éxito, presupuesto compartido de carga/inferencia y
cancelación durante espera.

SafetyAudioIsolationTests: retirar Safety conserva navegación interrumpida y narración.
DetectionPipelineRecoveryTests (iOS): carga fallida sin abrir cámara, reinicio con
flujos nuevos y detección sin profundidad, inferencia fallida que no se publica como
escena vacía, fin inesperado de captura.
SafetyServiceStopTests (iOS): aviso de modo con la primera inferencia, sin aviso de modo
si el modelo nunca corre, un solo aviso de pérdida y uno de recuperación, reintento.

La cámara real requiere hardware compatible y permiso previo; esos tests se omiten
cuando no están disponibles. Las pruebas de recuperación usan fábricas y frames falsos.

Package.swift y project.yml ya incluyen Tests/SafetyTests en develop. safety-validation.yml prepara
swift test en macOS y xcodebuild test en simulador, con el mismo Xcode del pipeline
existente. Al hacer push a esta rama, el pipeline existente feature/** también genera
IPA. Las pruebas y la distribución son workflows separados.

No hay Swift/Xcode configurado en el equipo Windows de implementación. La integración
con develop tampoco se compiló: compilación iOS, pruebas y resultados CI pendientes.

## Validación en iPhone

Registrar modelo, iOS exacto, commit y resultado. Probar en un lugar controlado.

1. Iniciar una ruta con modelo empaquetado y permiso de cámara: el estado debe pasar de
   preparando a activo tras la primera inferencia; sin objetos sigue activo.
2. Activar modo avión, desconectar Wi-Fi y mantener la cámara frente a objetos
   soportados. Detección local debe continuar sin red ni backend.
3. Revocar cámara desde Ajustes y volver: debe indicar no disponible y conservar
   acceso a Preferencias y Trayecto. Habilitar cámara y reintentar.
4. Terminar la ruta e iniciar otra varias veces: la detección debe reiniciar sin flujos
   terminados ni inferencias duplicadas. Comprobar VoiceOver y una llamada durante la ruta.
5. Para modelo ausente, preparar una compilación de prueba sin el recurso Core ML:
   la app debe abrir, al iniciar la ruta anunciar el fallo, seguir navegando y mostrar estado.
6. Para carga/inferencia transitorias, usar los tests con fábricas falsas: no corromper
   el modelo de la instalación de uso. Verificar 1/2/4 s mediante el reloj inyectado.
7. Confirmar que el aviso de fallo no se repite por frame y que la recuperación se
   anuncia solo después de una inferencia válida. Validar audios con VoiceOver.

## Límites y pendientes

El permiso de cámara lo prepara la compuerta de SCRUM-315 antes de iniciar la detección.
Si aun así la cámara está denegada o restringida, se publica como captura no disponible.
La recuperación maneja errores Swift lanzados por Core ML/Vision, no terminaciones
externas del proceso por el sistema operativo. El umbral térmico corresponde a SCRUM-321.
La evidencia de CI y las pruebas de dispositivo son necesarias antes de cerrar la HU.

Verificación local realizada: git diff --check, ausencia de marcadores de conflicto,
bloques de plataforma equilibrados y revisión de llamadas/tipos contra develop.
No equivale a compilar Swift.
