# Dashboard BQ5 — Recomendación personalizada de misiones

> **BQ5 (Type 2):** dado el tiempo disponible del usuario, su nivel de interacción social preferido, sus intereses y sus interacciones previas, ¿cuáles son las tres Sidequests disponibles más relevantes para la sesión actual?

El dashboard vive en **Supabase** (el mismo proyecto que usan Kotlin y Flutter) como un **reporte personalizado** con 7 paneles. Cada panel es un snippet SQL de solo lectura que se ejecuta en vivo sobre `public.analytics_events`, así que siempre muestra los datos actuales: no hay pipeline que correr, ni servidor ni herramienta nueva.

- Consultas: [`bq5_dashboard.sql`](bq5_dashboard.sql), un bloque `[BQ5-n]` por panel.
- Solo hacen `SELECT`: no crean, cambian ni borran nada en la base de datos.

## Por qué Supabase

| Alternativa | Problema |
| --- | --- |
| Pantalla de analítica dentro de la app | La RLS de `analytics_events` solo deja leer los eventos propios (`analytics_events_select_own`). Agregar datos de todos los usuarios exigiría una RPC `security definer` nueva en el backend y expondría la analítica a cualquier usuario de la app. |
| Streamlit de Sidequests-Analytics | Ya existe, pero requiere Python, `DATABASE_URL`, correr el pipeline para llenar `analytics.bq_results` y un hosting que aún no está desplegado. |
| **Reporte en Supabase Studio** | Persistente, accesible para todo el equipo desde el panel de Supabase, en vivo, sin código ni infraestructura nuevos. El SQL Editor corre con permisos de administrador, así que puede agregar datos de todos los usuarios sin abrir nada a la app. |

## Configuración (una sola vez, unos 10 minutos)

1. Entra a [supabase.com/dashboard](https://supabase.com/dashboard) y abre el proyecto de Sidequests.
2. **SQL Editor → New query.** Pega el bloque `[BQ5-1]` de `bq5_dashboard.sql` (desde su comentario hasta el `;`) y pulsa **Run** para comprobar que responde.
3. Renombra el snippet como `BQ5-1 Resumen` y guárdalo. Muévelo a la carpeta compartida del proyecto para que el resto del equipo lo vea.
4. Repite los pasos 2 y 3 con `[BQ5-2]` … `[BQ5-7]`.
5. **Reports → New custom report**, con el nombre `BQ5 Dashboard`.
6. **Add block → SQL snippet** para cada uno de los 7 snippets. Elige el tipo de gráfico que indica el comentario de cada bloque:

| Snippet | Gráfico | Eje X | Eje Y |
| --- | --- | --- | --- |
| BQ5-1 Resumen | Tabla | — | — |
| BQ5-2 Último top 3 por sesión | Tabla | — | — |
| BQ5-3 Aceptación por posición | Barras | `posicion` | `tasa_aceptacion_pct`, `tasa_descarte_pct` |
| BQ5-4 Ajuste al contexto | Barras | `criterio` | `pct_cumple` |
| BQ5-5 Tendencia 30 días | Líneas | `dia` | `listas_mostradas`, `aceptadas`, `descartadas` |
| BQ5-6 Misiones más recomendadas | Barras | `mision` | `impresiones_unicas`, `aceptadas` |
| BQ5-7 Contexto de entrada | Barras | `nivel_social` | `listas` |

Si tu plan o versión de Supabase no muestra **Reports → custom report**, los mismos snippets guardados funcionan como dashboard: ábrelos en el SQL Editor, pulsa **Run** y cambia a la vista **Chart**.

## Cómo consultarlo en cualquier momento

Panel de Supabase → proyecto Sidequests → **Reports → BQ5 Dashboard**. Cada vez que lo abres o lo refrescas, las consultas vuelven a correr sobre los datos actuales. Los snippets siguen disponibles en el **SQL Editor**, en la carpeta compartida.

## Qué muestra cada panel

| Panel | Pregunta que responde | Cómo leerlo |
| --- | --- | --- |
| **BQ5-1 Resumen** | ¿Cuánto se usa la recomendación? | Listas servidas, sesiones, usuarios, % de listas con 3 misiones, % de impresiones aceptadas/descartadas, % de sesiones con al menos una aceptación. |
| **BQ5-2 Último top 3 por sesión** | La respuesta de BQ5 en sí | Las 3 misiones de la última lista de cada una de las 15 sesiones más recientes, con el contexto con que se pidieron (tiempo, nivel social y su fuente, modo de ubicación) y qué hizo el usuario. Es la misma lógica que `BQ5_PERSONALIZED_RECOMMENDATION_SQL` en Sidequests-Analytics. |
| **BQ5-3 Aceptación por posición** | ¿El orden tiene sentido? | Si el ranking es relevante, la posición #1 debería tener la mayor tasa de aceptación. |
| **BQ5-4 Ajuste al contexto** | ¿Se respetan las entradas de BQ5? | **Tiempo** e **historial** son filtros duros de `recommend_quests`, así que deben dar **100%**; un valor menor indica un error. Nivel social, intereses y modo de ubicación suman puntos: cuanto más alto, mejor, pero el 100% no está garantizado. |
| **BQ5-5 Tendencia 30 días** | ¿Cómo evoluciona el uso? | Listas mostradas, aceptaciones y descartes por día, en hora de Bogotá. |
| **BQ5-6 Misiones más recomendadas** | ¿Qué se recomienda y qué funciona? | Las 10 misiones con más impresiones, su tasa de aceptación y su posición promedio. |
| **BQ5-7 Contexto de entrada** | ¿Con qué contexto se pide? | Listas por nivel social y su fuente: el perfil o "¿Cómo te sientes hoy?", que cambia el nivel solo para la sesión en Flutter. Incluye el tiempo disponible promedio y el modo de ubicación. |

## Reglas y limitaciones

- **Lista:** una respuesta de la RPC. Se identifica por `metadata.batch_id`, o por sesión + segundo cuando el cliente no lo envía (el mismo criterio que Sidequests-Analytics).
- **Posición:** `metadata.rank`; si falta, el orden de los eventos dentro de la lista. Así se cuentan también los eventos que no traen `rank`, que la consulta de Sidequests-Analytics descarta.
- **Impresión única:** una por usuario + sesión + misión, para que recargar la misma lista no infle las tasas (la misma regla que BQ9). Una aceptación o un descarte se asocia a lo mostrado por usuario + sesión + misión (la misma regla que BQ8 y BQ9).
- **Intereses:** el panel BQ5-4 usa los intereses actuales del usuario, porque no se guardan en cada evento.
- **Plataforma:** los eventos no indican si vienen de Kotlin o de Flutter, así que el dashboard muestra ambas apps juntas, como corresponde a una BQ compartida.

## Validación

Las 7 consultas se ejecutaron contra las migraciones 001–008 y el `seed.sql` de Sidequests-Backend, en un Postgres local, con sesiones simuladas como las generan las apps:

- llamadas reales a `recommend_quests`;
- eventos `recommendation_shown` con `rank`, `batch_id` y `social_level_source`;
- un descarte seguido de la recarga que excluye la misión;
- una lista sin `rank` ni `batch_id`.

Se comprobaron los conteos, las posiciones, los filtros duros (tiempo e historial al 100%) y la tendencia diaria.
