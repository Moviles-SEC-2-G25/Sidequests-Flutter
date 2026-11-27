# Comportamiento sin conexión (modo avión)

Qué hace cada parte de la app cuando el teléfono no tiene internet. La regla:
lo que puede funcionar con datos guardados en el teléfono sigue funcionando; lo
que necesita el servidor se bloquea **antes** de que el usuario lo intente, con
un aviso que explica por qué.

El estado de conexión lo publica `ConnectivityViewModel` (por encima de
`MaterialApp`, así que lo ven todas las pantallas, incluidas login y las que se
abren encima del menú inferior). Los avisos usan `OfflineNotice` y los textos de
`OfflineMessages` (`lib/view/widgets/offline_notice.dart`).

## Funciona sin conexión

| Pantalla / acción | Cómo |
| --- | --- |
| Abrir la app con sesión guardada | Sesión, desbloqueo con huella y onboarding se deciden en el teléfono. |
| Explorar: catálogo, recomendaciones, filtros, "Ahora no" | Última versión guardada, marcada "Recomendaciones guardadas" / "Según tus datos guardados". |
| Detalle de una misión | Datos y pasos guardados; clima con el último dato conocido o "Clima no disponible sin conexión". |
| Cerca: lista y "Activar ubicación" | El GPS no necesita internet. |
| Misión activa: ver pasos, podómetro, check-in por ubicación | El check-in verificado queda guardado y se aplica al reconectar. |
| Misión activa: tomar foto de verificación | La foto queda en el teléfono y se sube sola al reconectar. |
| Abandonar una misión ("Salir") y ver alternativas | El abandono queda en cola; las alternativas se calculan en el teléfono. |
| Calificar una misión completada | La calificación queda en cola. |
| Perfil, insignias, recompensas, "Mis estadísticas" | Con los datos guardados, avisando que son del último acceso. |
| "Mi bitácora": historial, búsqueda y filtros | Con los datos guardados; marca "Pendiente de sincronizar" lo hecho sin conexión y se actualiza sola al reconectar (detalle en `BITACORA.md`). |
| Modo oscuro, notificaciones locales, huella | Ajustes locales. |
| Agitar para una misión sorpresa | Prioriza misiones con pasos guardados; iniciarla sigue necesitando conexión. |
| Retos en grupo (Explorar → "Descubre más"): ver "Mis retos", "Retos disponibles", progreso y siguiente paso | Última versión de cada lista guardada en el teléfono (sobrevive a reiniciar la app), con el aviso "Retos cargados antes · conéctate para hacer cambios". Se borra al cerrar sesión. |

Al reconectar, la app sincroniza lo que quedó en cola (inicios de versiones
anteriores, abandonos, calificaciones, fotos, analítica) y recarga los datos.
Retos en grupo recarga sus dos listas cuando la conexión se mantiene 3 s; una
solicitud pendiente **no** se reenvía sola (ver abajo).

## Bloqueado sin conexión (con aviso)

| Acción | Qué ve el usuario |
| --- | --- |
| Iniciar una misión ("Empezar ya", "Aceptar misión") | Botón "Sin conexión" desactivado y aviso. Su progreso solo se guarda en el servidor, así que ya **no** se inicia en el teléfono. Una misión ya iniciada sí se puede abrir y revisar. |
| Completar un paso o la misión | Aviso en la misión y botón "Conéctate para completar" desactivado. |
| Reintentar subida de foto | Se oculta; el aviso indica que se subirá sola. |
| Iniciar sesión, registrarse | Aviso y botón desactivado. |
| Entrar con código (OTP) | Aviso y botones desactivados (ya existía). |
| Cambiar contraseña | Mensaje al tocar el ícono, sin abrir el formulario. |
| Guardar preferencias (perfil y onboarding) | Aviso y "Guardar"/"Continue" desactivados. |
| Cerrar sesión | Se permite, pero primero pide confirmar: sin conexión no se puede volver a entrar y se pierde lo no sincronizado. |
| Retos en grupo: "Crear reto", "Unirme", "Marcar siguiente paso", actualizar | Botones desactivados y aviso. No se encolan: el servidor decide y registra cada solicitud (BQ2). |
| Retos en grupo: "Reintentar solicitud pendiente" | Desactivado sin conexión. Si una solicitud salió pero no llegó respuesta (se cayó la red, 5 s sin respuesta), queda guardada con su `request_id` y se muestra "No sabemos si se guardó. Reconecta y reintenta: es seguro."; al reconectar, el botón la reenvía con el mismo `request_id` y el servidor no la aplica dos veces. Mientras está pendiente, las demás acciones esperan. |

Si el teléfono dice tener conexión pero la red no responde (Wi‑Fi sin
internet), cada llamada tiene límite de tiempo (5 s datos, 15 s autenticación)
y termina con un mensaje claro; ningún botón queda cargando para siempre.

## Versión de entrega (sin indicadores de depuración)

- `debugShowCheckedModeBanner: false` quita la cinta "DEBUG".
- Las franjas amarillas/negras con texto rojo "OVERFLOWED BY … PIXELS" eran
  desbordamientos reales en el detalle de misión (tarjetas de duración/costo/
  social), Perfil (insignias), Explorar y login con teclado abierto; se
  corrigieron para teléfonos de 320–360 dp y texto del sistema al 130 %.
- Para instalar la versión de entrega:

  ```sh
  flutter build apk --release
  flutter install            # con el teléfono conectado por USB
  # o, en un solo paso: flutter run --release
  ```

  `flutter run` sin `--release` instala una compilación de depuración.
