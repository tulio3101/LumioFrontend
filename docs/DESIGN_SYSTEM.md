# Lumio: identidad visual, color y accesibilidad

Estado: propuesta de diseño para implementar y validar.

## Propósito

Lumio busca apoyar la independencia de personas con discapacidad visual severa. Su interfaz debe ser útil, minimalista, predecible y accesible. El símbolo de las manos sosteniendo una luz expresa cuidado y acompañamiento; el azul conecta esa identidad con las acciones de la aplicación.

La accesibilidad no depende únicamente de la paleta: requiere contraste, texto adaptable, controles comprensibles, compatibilidad con VoiceOver y alternativas sonoras y hápticas cuando sean pertinentes.

## Principios de diseño

- Priorizar una acción principal por pantalla.
- Usar fondos neutros y reservar el azul para acciones y selección.
- Reservar verde, ámbar y rojo para comunicar estados concretos.
- Evitar degradados detrás de texto, transparencias que reduzcan contraste y decoración innecesaria.
- Mantener etiquetas visibles, instrucciones breves y una navegación consistente.
- Ofrecer temas claro y oscuro; respetar inicialmente la apariencia del sistema y permitir elegirla en preferencias.
- No asumir que el tema oscuro beneficia a todas las personas con baja visión.

## Identidad de marca

El azul de referencia de la marca es `#087FAE`. Es una aproximación de diseño al logo, no una medición de todos sus píxeles.

Para acciones en tema claro se utiliza un azul más oscuro, `#00658A`, que proporciona mayor contraste con texto blanco. En tema oscuro se utiliza `#76D4F5`, con texto oscuro en botones rellenos.

El icono mantiene las manos, el círculo y la estrella, con trazos gruesos y sin textos. El logo completo puede aparecer en presentaciones o pantallas de bienvenida, sin reemplazar instrucciones o controles.

## Paleta por función

Usar nombres semánticos al implementar: cada color representa una función y cambia con el tema.

| Función / token | Tema claro | Tema oscuro | Uso |
|---|---|---|---|
| `background` | `#F5F8FA` | `#10212B` | Fondo general |
| `surface` | `#FFFFFF` | `#192F3B` | Formularios, tarjetas y paneles |
| `textPrimary` | `#172B36` | `#F3F7FA` | Títulos, instrucciones y contenido |
| `textSecondary` | `#465D69` | `#BBCBD4` | Descripciones y ayudas |
| `actionPrimary` | `#00658A` | `#76D4F5` | Botones principales, enlaces e iconos de acción |
| `onActionPrimary` | `#FFFFFF` | `#10212B` | Texto e iconos dentro del botón principal |
| `controlBorder` | `#70838D` | `#829BAA` | Contornos necesarios para identificar campos y controles |
| `focusRing` | `#00658A` | `#76D4F5` | Indicador de foco sobre fondos neutros |

El azul de marca no sustituye automáticamente a `actionPrimary`. No usar texto blanco sobre el azul claro de acción del tema oscuro.

### Aplicación del tema oscuro

- Usar `background` en la pantalla y `surface` en los grupos de contenido que necesiten separación.
- Mantener texto principal claro y texto secundario legible; no reducir su opacidad para restarle importancia.
- Usar botones principales azul claro con texto oscuro.
- Los botones secundarios pueden usar fondo de superficie, texto de acción y borde funcional.
- La diferencia entre fondo y superficie es sutil: cuando el contorno sea necesario para reconocer un control, añadir `controlBorder`.
- Separar el anillo de foco del control con un espacio del color del fondo. Un anillo del mismo azul pegado a un botón azul puede resultar invisible.
- Definir los colores por tema, sin invertir automáticamente imágenes o colores de estado.

## Estados y mensajes

Cada estado combina color, icono y texto. Los colores siguientes están pensados como texto e iconos sobre su fondo asociado.

| Estado | Texto/icono claro | Fondo claro | Texto/icono oscuro | Fondo oscuro | Ejemplo |
|---|---|---|---|---|---|
| Confirmación | `#18734A` | `#EAF6EF` | `#83DFAC` | `#16392B` | «Destino guardado» |
| Advertencia | `#875400` | `#FFF4D6` | `#FFD581` | `#40321B` | «Señal GPS débil» |
| Error | `#B42318` | `#FDECE9` | `#FFB4AB` | `#452522` | «No se pudo calcular la ruta» |

No usar verde como garantía de seguridad del entorno. Los mensajes deben describir únicamente estados que la aplicación haya podido comprobar.

Durante la navegación, las alertas relevantes deben contar con comunicación por voz y, cuando corresponda, vibración. Coordinar estos avisos con el sistema de audio de Lumio para evitar mensajes superpuestos o repetitivos.

## Contraste verificado

Relaciones calculadas con la luminancia relativa sRGB de los valores hexadecimales indicados, sin transparencia y redondeadas a dos decimales. Cambiar el fondo, la opacidad o el color requiere comprobar nuevamente la combinación.

### Tema claro

| Primer plano | Fondo | Contraste |
|---|---|---|
| Blanco `#FFFFFF` | Acción `#00658A` | 6,50:1 |
| Texto principal `#172B36` | General `#F5F8FA` | 13,72:1 |
| Texto secundario `#465D69` | General `#F5F8FA` | 6,50:1 |
| Texto secundario `#465D69` | Superficie `#FFFFFF` | 6,93:1 |
| Acción `#00658A` | General `#F5F8FA` | 6,10:1 |
| Borde `#70838D` | General `#F5F8FA` | 3,70:1 |
| Borde `#70838D` | Superficie `#FFFFFF` | 3,95:1 |
| Confirmación `#18734A` | `#EAF6EF` | 5,27:1 |
| Advertencia `#875400` | `#FFF4D6` | 5,81:1 |
| Error `#B42318` | `#FDECE9` | 5,75:1 |

### Tema oscuro

| Primer plano | Fondo | Contraste |
|---|---|---|
| Texto principal `#F3F7FA` | General `#10212B` | 15,30:1 |
| Texto principal `#F3F7FA` | Superficie `#192F3B` | 12,90:1 |
| Texto secundario `#BBCBD4` | General `#10212B` | 9,89:1 |
| Texto secundario `#BBCBD4` | Superficie `#192F3B` | 8,34:1 |
| Acción `#76D4F5` | General `#10212B` | 9,81:1 |
| Acción `#76D4F5` | Superficie `#192F3B` | 8,28:1 |
| Texto del botón `#10212B` | Acción `#76D4F5` | 9,81:1 |
| Borde `#829BAA` | General `#10212B` | 5,66:1 |
| Borde `#829BAA` | Superficie `#192F3B` | 4,78:1 |
| Confirmación `#83DFAC` | `#16392B` | 7,93:1 |
| Advertencia `#FFD581` | `#40321B` | 8,93:1 |
| Error `#FFB4AB` | `#452522` | 8,03:1 |

Como referencia, WCAG AA establece 4,5:1 para texto normal y 3:1 para texto grande; los elementos visuales necesarios para identificar controles y estados requieren 3:1 frente a los colores adyacentes. Los bordes del tema claro son para controles, no para texto normal.

Estas verificaciones cubren las combinaciones listadas; no certifican la accesibilidad de la aplicación completa.

## Componentes y comportamiento

### Botones

- Acción principal: relleno `actionPrimary` y contenido `onActionPrimary`.
- Acción secundaria: superficie neutra, etiqueta clara y contorno cuando sea necesario.
- Usar verbos concretos: «Calcular ruta», «Guardar destino», «Detener asistencia».
- Comunicar selección con una marca o etiqueta además del color.
- Durante una operación, mostrar una etiqueta como «Calculando ruta» y anunciar el cambio a las tecnologías de asistencia.
- Para acciones deshabilitadas, comunicar el estado y explicar el requisito pendiente cuando no sea evidente; no depender únicamente de reducir la opacidad.

### Campos y mensajes

- Mantener una etiqueta visible; el texto de ejemplo dentro del campo no reemplaza su nombre.
- Asociar los errores con el campo o la operación correspondiente.
- Explicar qué ocurrió y, cuando sea posible, cómo resolverlo.
- Evitar transmitir información únicamente mediante posición, forma o color.

## Accesibilidad en iOS y SwiftUI

Estas son decisiones de diseño propuestas para Lumio, que deben probarse en dispositivos reales:

- Usar estilos tipográficos del sistema y Dynamic Type; permitir que el diseño crezca y se reorganice.
- Evitar alturas fijas en contenedores de texto y truncamientos de instrucciones importantes.
- Proponer áreas táctiles de al menos 44 × 44 puntos y ampliarlas para acciones principales cuando el espacio lo permita.
- Dar a los controles nombres accesibles que coincidan con sus etiquetas visibles.
- Mantener un orden de lectura y foco lógico para VoiceOver.
- Anunciar resultados y errores sin repetir innecesariamente el contenido ni interrumpir avisos prioritarios.
- Respetar las preferencias de reducción de movimiento y mayor contraste.
- No hacer que las funciones esenciales dependan de gestos complejos sin alternativa visible o accesible.
- Representar los colores con recursos semánticos de apariencia clara y oscura, evitando valores dispersos por las vistas.
- Validar por separado cualquier variante de mayor contraste; no asumir que oscurecer o aclarar todos los colores la hace accesible.

## Ejemplo: pantalla de destino

1. Fondo general del tema elegido.
2. Título «¿A dónde quieres ir?» en texto principal.
3. Campo con etiqueta «Dirección o lugar», fondo de superficie y borde funcional.
4. Botón principal «Calcular ruta», con la combinación de acción del tema.
5. Descripciones auxiliares en texto secundario.
6. Si ocurre un error, icono y mensaje explícito sobre el fondo de error, con anuncio accesible.

Los ejemplos describen el diseño esperado; no implican que las funciones de navegación o asistencia estén implementadas.

## Validación antes de publicar

- Revisar ambas apariencias, incluyendo campos, estados, selección y foco.
- Comprobar el contraste sobre los fondos reales, especialmente si se introducen fotografías, mapas o transparencias.
- Recorrer las tareas principales con VoiceOver y tamaños de texto de accesibilidad.
- Confirmar que la interfaz sigue siendo comprensible sin distinguir los colores.
- Probar los controles con personas con baja visión y personas usuarias de lectores de pantalla.
- Revisar la coordinación de voz, vibración y mensajes visuales en situaciones de uso reales.

## Referencias

- [W3C: contraste mínimo de texto](https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum/).
- [W3C: WCAG 2.2](https://www.w3.org/TR/wcag/), especialmente uso del color (1.4.1) y contraste no textual (1.4.11).

WCAG se utiliza aquí como referencia para el diseño y la evaluación del contraste; la experiencia nativa de iOS requiere además validación funcional con sus tecnologías de asistencia.
