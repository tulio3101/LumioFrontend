# HU: Recuperar Contraseña

Como usuario registrado con cuenta propia, quiero recuperar el acceso a mi cuenta cuando no
recuerde mi contraseña para volver a usar la aplicación sin crear una cuenta nueva.

Solo cuentas propias: Google y Apple no usan contraseña de Lumio.

## Flujo

Iniciar sesión → «¿Olvidaste tu contraseña?» (solo en modo iniciar sesión) abre
PasswordRecoveryView en una hoja:

1. Correo → «Enviar código». El backend (POST /users/password-reset) responde siempre 202 y la
   app dice siempre lo mismo: «Si el correo corresponde a una cuenta con contraseña, te
   enviamos un código…». No revela si la cuenta existe.
2. Código de 6 dígitos (el campo usa `oneTimeCode`: iOS puede sugerirlo desde el correo; se
   aceptan espacios), nueva contraseña (8 a 128, como al crear la cuenta) y confirmación →
   «Restablecer contraseña» (POST /users/password-reset/confirm). «Enviar otro código» y
   «Usar otro correo».
3. «Iniciar sesión» vuelve al formulario con el correo escrito y el foco en la contraseña.

Reglas del backend: el código vence a los 15 minutos, admite 5 intentos, solo vale el último y
entre dos pedidos debe pasar un minuto. Se guarda solo su hash. El correo lo incluye también
dígito a dígito para los lectores de pantalla. Al restablecer se cierran las sesiones de todos
los dispositivos.

## Audio y VoiceOver

PasswordRecoveryService locuta cada resultado por el AudioArbiter como P2 (contexto
`password-recovery`) y la pantalla muestra el mismo texto en un aviso. Los errores de cada
campo van en su pista de VoiceOver. No se mueve el foco para no superponer VoiceOver con la voz
de Lumio. Fallos (todos dicen que la contraseña sigue igual): sin conexión, código no válido o
vencido (sin más detalles), datos rechazados, error del servidor, backend no configurado.

## Pruebas automatizadas

- PasswordRecoveryTests: pedir código (mismo mensaje, correo inválido no se envía, sin red),
  restablecer (código con espacios, código rechazado, datos inválidos), clasificación de errores,
  reglas, contrato HTTP (rutas, POST, sin Authorization, cuerpo `new_password`) y la pantalla
  (pasos y errores de campo tras el primer intento).
- Backend: tests/modules/users/test_password_reset.py y
  tests/integration/test_password_reset_api.py.

## Validación en iPhone (con VoiceOver)

1. Iniciar sesión → «¿Olvidaste tu contraseña?» → escribir el correo → «Enviar código»: se oye
   el aviso y llega el correo.
2. Escribir el código (o aceptar la sugerencia del teclado), la nueva contraseña dos veces →
   «Restablecer contraseña»: se oye «Contraseña restablecida…».
3. «Iniciar sesión» con la nueva contraseña. En otro dispositivo con sesión, la sesión se cerró.
4. Un código incorrecto o uno anterior: «El código no es válido o ya venció…».
5. Un correo que no existe: el mismo aviso del paso 1, sin correo.
