# HU: Iniciar sesión con Google (SCRUM-62)

Permitir iniciar sesión con una cuenta de Google y asociarla a la cuenta de Lumio. El flujo
debe ser usable con VoiceOver y manejar errores (cancelación, sin red) con mensajes por audio.

Subtarea de SCRUM-2 (Iniciar Sesión). Crear la cuenta con Google (SCRUM-68) usa el mismo botón:
la primera vez el backend crea la cuenta sin contraseña.

## Flujo

Crear cuenta o Iniciar sesión → «Continuar con Google»:

1. Sin red (según `NetworkConnectivityMonitor`) no se abre Google: se dice «Sin conexión…».
2. Se abre la hoja del sistema de Google (`ASWebAuthenticationSession`). iOS pregunta antes si
   Lumio puede usar google.com; es una alerta del sistema que VoiceOver lee. La hoja comparte
   la sesión de Google de Safari.
3. La persona elige su cuenta. El código de autorización se cambia por el ID token en
   `oauth2.googleapis.com/token` con PKCE (S256), `state` y `nonce`, sin secreto de cliente.
4. POST /users/login/google con el ID token. El backend lo verifica y entra o crea la cuenta.
   Los tokens de Lumio se guardan en Keychain, como con correo, y se abre la pantalla principal,
   que anuncia su estado.

No se usa el SDK de Google: es el mismo flujo OAuth que usa el SDK, sin añadir dependencias al
paquete.

### Asociar Google a una cuenta con contraseña

Si el correo de Google ya es de una cuenta con contraseña, el backend no las une solo (409
`google_account_conflict`), porque el registro con correo no verifica el correo. Lumio dice:
«Ya existe una cuenta de Lumio con ese correo. Inicia sesión con tu correo y contraseña y
después asocia Google desde Preferencias, Mi cuenta.»

En Preferencias > Mi cuenta, la sección «Cuenta de Google» muestra «Asociar cuenta de Google»
mientras la cuenta no tenga una (`google_linked` de GET /users/me). Abre la misma pantalla de
Google y envía el ID token a POST /users/me/google con la sesión iniciada. Desde entonces se
puede entrar con Google o con la contraseña. Las cuentas creadas con Google ya la tienen.

## Audio y VoiceOver

Todo lo que se dice pasa por el AudioArbiter con prioridad `routeInformation`:

- Inicio de sesión: `AnnouncedAuthenticationService` + `GoogleSignInAnnouncer` (contexto
  `google-sign-in`). Un aviso nuevo reemplaza al anterior y vence a los 60 s.
- Asociar desde Mi cuenta: `ProfileService` (contexto `account-profile`, como el resto del perfil).

La pantalla muestra el mismo texto en el aviso de error (`GoogleSignInAnnouncements`). Como ya lo
dijo el árbitro, AccountFormView no lo repite con un anuncio de VoiceOver (`isAnnouncedByAudio`).
El botón de Google tiene etiqueta «Continuar con Google» (o «Conectando con Google…») y el logo
está oculto para VoiceOver.

| Caso | Qué se dice |
| --- | --- |
| Cancelar la hoja de Google | «Cancelaste el inicio de sesión con Google. Puedes intentarlo de nuevo o usar tu correo.» |
| Sin red (antes o durante) | «Sin conexión. No se pudo continuar con Google. Intenta de nuevo cuando tengas conexión.» |
| Correo de una cuenta con contraseña (409) | Iniciar con la contraseña y asociar Google en Mi cuenta |
| Token rechazado o correo sin verificar (401/403) | «Google no confirmó tu cuenta…» |
| Cuenta de Google de otra cuenta de Lumio (409 al asociar) | «No se pudo asociar: esa cuenta de Google ya está asociada a otra cuenta de Lumio…» |
| Google sin configurar en la app o el servidor (503) | «El inicio de sesión con Google no está disponible por ahora. Usa tu correo y contraseña.» |
| Otro error | «No se pudo continuar con Google. Intenta de nuevo en unos momentos.» |
| Asociada | «Tu cuenta de Google quedó asociada. Ya puedes iniciar sesión con Google.» |

Si la red se cae con la hoja de Google abierta, la hoja muestra el error de Safari; al cerrarla
se dice el mensaje de cancelación.

Al entrar con éxito no se dice nada aquí: la pantalla principal anuncia la sesión al abrirse.

## Configuración

`Resources/Info.plist` → `GoogleClientID`: el client ID de **tipo iOS** de Google Cloud
(`xxx.apps.googleusercontent.com`, bundle ID `com.lumio.app`). No es secreto. La redirección es
el client ID invertido (`com.googleusercontent.apps.xxx:/oauth2redirect`); no hace falta
registrar un URL type porque la hoja captura la redirección. El mismo client ID debe estar en
`GOOGLE_CLIENT_IDS` del backend. Vacío: el botón dice que Google no está disponible.

## Piezas

- Dominio: `GoogleSignIn.swift` (`GoogleIDToken`, `GoogleIDTokenProviding`,
  `GoogleSignInFailure`, `GoogleLinkOutcome`, textos).
- Datos: `GoogleOAuth.swift` (URL de autorización, PKCE, redirección, intercambio del código),
  `WebGoogleIDTokenProvider` (solo iOS), `AuthAPI.loginWithGoogle`,
  `RemoteProfileService.linkGoogle`.
- Aplicación: `RemoteAuthenticationService.signInWithGoogle`, `AnnouncedAuthenticationService`,
  `ProfileService.linkGoogle`.
- Presentación: `AccountFormViewModel.signInWithGoogle`, sección «Cuenta de Google» en
  ProfileView.
- Backend: POST /users/login/google y POST /users/me/google; `google_linked` en GET /users/me.

## Pruebas automatizadas

- GoogleSignInTests: client ID y redirección, URL de autorización con PKCE, reto S256, `state`
  de la redirección, intercambio del código, correo del ID token, contrato de
  /users/login/google y /users/me/google y sus errores, sesión guardada sin audio, cancelación,
  sin red (no se abre Google), red caída a mitad, 409 con instrucciones, Keychain que falla,
  Google sin configurar, pantalla de acceso (sin repetir con VoiceOver) y asociar desde Mi
  cuenta (éxito, cancelación, sin red, cuenta de otro, sesión vencida, botón oculto al asociar).
- Backend: tests/modules/users/test_login_google.py y test_link_google.py.

## Validación en iPhone (con VoiceOver)

1. Poner `GoogleClientID` en el Info.plist y el mismo valor en `GOOGLE_CLIENT_IDS` del backend.
2. Crear cuenta → «Continuar con Google» → aceptar la alerta → elegir cuenta: entra a la
   pantalla principal. Cerrar sesión y repetir: entra a la misma cuenta.
3. Cerrar la hoja de Google sin elegir: se oye el mensaje de cancelación y el aviso queda en
   pantalla.
4. Modo avión → «Continuar con Google»: no se abre Google y se oye «Sin conexión…».
5. Con una cuenta de correo y contraseña cuyo correo sea el de Google: «Continuar con Google»
   explica cómo asociarla; entrar con la contraseña → Preferencias > Mi cuenta → «Asociar cuenta
   de Google» → se oye la confirmación. Cerrar sesión y entrar con Google.
