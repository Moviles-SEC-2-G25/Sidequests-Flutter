# Mi bitácora (historial de misiones)

Vista y feature del sprint 4. Este documento es el contrato para replicarla
en Kotlin: si ambas apps siguen estas reglas, muestran exactamente lo mismo.

Código Flutter:

| Pieza | Archivo |
| --- | --- |
| Lógica pura (lo que corre en segundo plano) | `lib/core/mission_history.dart` |
| ViewModel (carga, debounce, hilo de fondo) | `lib/viewmodel/profile/mission_history_view_model.dart` |
| Vista | `lib/view/profile/mission_history_view.dart` |
| Pruebas de las reglas (casos para portar) | `test/core/mission_history_test.dart` |

## Qué ve el usuario

Desde **Perfil → "Completadas recientemente" → "Ver bitácora"** se abre
"Mi bitácora": todas sus misiones intentadas, agrupadas por mes, con
buscador y filtros. Funciona sin conexión con los datos guardados.

- Buscador: "Buscar misión, lugar o categoría", con botón para borrar.
- Filtros: **Todas · Completadas · Abandonadas**.
- Contador: "N misiones en tu bitácora"; con filtro o búsqueda,
  "Mostrando X de N misiones" (singular "misión" cuando N = 1).
- Barra de progreso fina (2 dp, altura fija) mientras se calcula en segundo plano.
- Encabezado de mes: "Noviembre 2026" y debajo, por ejemplo,
  "2 completadas · 1 abandonada · 1 en curso · 105 min · 1.500 pasos".
  Se omite cada parte en 0 o sin dato; singular cuando es 1
  ("1 completada", "1 paso"). Miles con punto ("1.500").
- Cada misión: emoji (🎯 si no hay), título (máx. 2 líneas),
  "Nov 2 · Gastronomía · 45 min", y cómo terminó:
  - **Completada** (verde) + estrellas "★★★★☆", o "Sin calificar".
  - **Abandonada** (rojo) + emoji y texto del motivo (`AbandonmentReason`).
  - **En curso** (morado).
  - Si hay dato del podómetro: "🚶 1.234 pasos".
  - Al tocarla se abre el detalle de la misión, salvo que ya no esté en el catálogo.
- Jalar hacia abajo recarga.

Estados:

| Situación | Qué se muestra |
| --- | --- |
| Cargando la primera vez | Spinner |
| Con conexión y sin intentos | "Tu bitácora está vacía. ¡Acepta una misión en Explorar para empezarla!" + **Volver** |
| Sin conexión y nada guardado | "Sin conexión y sin datos guardados. Tu bitácora se cargará sola cuando vuelva el internet." + **Reintentar** |
| Filtro/búsqueda sin resultados | "Ninguna misión coincide" / "Prueba con otra palabra o cambia el filtro." |
| Al recargar | La lista actual sigue visible hasta que llega la nueva, con la barra de progreso |

Los avisos de conexión están en [Conectividad eventual](#conectividad-eventual).

## Reglas (deben dar igual en ambas apps)

Entrada: catálogo (`quests`), intentos del usuario (`user_quests`, del
servidor o de la caché), pasos por intento (podómetro, local), filtro y texto
de búsqueda.

1. **Qué entra.** Todo intento con `status != 'skipped'`. Ese número es el
   total de la bitácora (antes de filtro y búsqueda); si es 0, la bitácora
   está vacía.
2. **Filtros.** Todas = regla 1. Completadas = `completed`. Abandonadas =
   `abandoned`. "En curso" (`accepted` o `in_progress`) solo aparece en Todas.
3. **Fecha de cada intento.** `completed` → `completed_at`; `abandoned` →
   `abandoned_at`; cualquier otro → `started_at`. Si ese campo es null,
   `accepted_at`. Siempre convertida a **hora local** del teléfono.
4. **Orden.** Fecha descendente. Empate: `id` del intento ascendente
   (comparación de texto). Nunca depende del orden en que llegó la lista.
5. **Meses.** Se agrupa por (año, mes) de la fecha local; del más reciente al
   más antiguo.
6. **Totales del mes** (solo de lo que se muestra, así que siguen al filtro y
   a la búsqueda):
   - completadas, abandonadas y en curso: conteos por estado;
   - minutos: suma de `duration_minutes` de las **completadas** cuya misión
     está en el catálogo;
   - pasos: suma de los pasos de los intentos que tienen dato; **null si
     ninguno tiene** (no es 0, y no se muestra).
7. **Búsqueda.**
   - Normalizar: minúsculas → quitar tildes con esta tabla fija → recortar
     espacios → varios espacios seguidos pasan a uno.

     | Letras | Queda |
     | --- | --- |
     | á à ä â | a |
     | é è ë ê | e |
     | í ì ï î | i |
     | ó ò ö ô | o |
     | ú ù ü û | u |
     | ñ | n |

     En Kotlin: `lowercase()` (sin `Locale`), no `java.text.Normalizer`, para
     que el resultado sea idéntico al de Dart.
   - Partir la consulta normalizada en palabras. Cada palabra debe aparecer
     (como substring) en el texto normalizado de:
     `title + " " + location_name + " " + category + " " + etiqueta en español de category`.
     El orden de las palabras no importa.
   - Si la misión ya no está en el catálogo, solo se busca en su `quest_id`.
   - Consulta vacía o solo espacios = sin búsqueda.
   - Etiquetas: outdoors → Aire libre, food → Gastronomía, art → Arte,
     learning → Aprendizaje, mindfulness → Bienestar, movement → Movimiento,
     social → Social; otra categoría → su valor tal cual.
8. **Misión fuera del catálogo.** Título = `quest_id`, sin minutos, sin
   categoría, no se puede abrir; cuenta en los conteos del mes.
9. **Pendiente de sincronizar.** Un intento lo está si su `id` tiene alguna
   escritura en la cola offline (aceptación, calificación o abandono hechos
   sin conexión). Se marca en su fila, y el conteo de pendientes se hace sobre
   la regla 1, sin importar filtro ni búsqueda. La lista de pendientes se lee
   **después** de leer los intentos, porque esa lectura sincroniza la cola
   primero. Si la app Kotlin no tiene cola offline, nunca hay pendientes.

## Conectividad eventual

Una vez cargada, todo lo que muestra la bitácora está en el teléfono: la
búsqueda y los filtros funcionan sin internet. La pantalla sigue la
conexión mientras está abierta y se pone al día sola cuando vuelve.

| Escenario | Comportamiento |
| --- | --- |
| Se va el internet con la pantalla abierta | Aparece al instante el aviso "Sin conexión: estás viendo tu bitácora guardada. Se actualizará sola cuando vuelva el internet." La lista sigue igual y no se le pide nada al servidor. |
| Abrirla sin internet, con datos guardados | La lista guardada + el mismo aviso. |
| Abrirla sin internet y sin nada guardado | Mensaje de error (ver Estados). Se carga sola cuando vuelve la conexión. |
| Cambios hechos sin conexión (abandonar o calificar) | Aparecen ya con su nuevo estado, con la marca "Pendiente de sincronizar" en su fila; el aviso suma "N misiones con cambios por sincronizar." |
| Vuelve el internet | Aviso "Conectado: actualizando tu bitácora…". Se espera **3 s** a que la conexión se mantenga; luego se recarga: primero se envía la cola y después se leen los datos del servidor. Al terminar, se van el aviso y las marcas de pendiente. |
| La conexión vuelve y se cae antes de 3 s | No se recarga (una conexión intermitente no dispara peticiones). |
| Una carga empezó sin internet y la conexión vuelve mientras tanto | Se espera a que termine y después se recarga con conexión. |
| El teléfono dice tener red pero el servidor no responde (Wi‑Fi sin internet) | A los 5 s se muestra lo guardado con el aviso "No pudimos conectar con el servidor: estás viendo tu bitácora guardada. Desliza hacia abajo para reintentar." |
| Jalar para recargar mientras ya hay una recarga en curso | Se comparte la misma; no se hacen dos lecturas. |
| Se cierra la pantalla esperando la reconexión | Se cancela la espera; no se carga nada después. |

Orden de prioridad del aviso: sin red → "Sin conexión…"; con red y datos
guardados mientras se recarga o espera los 3 s → "Conectado: actualizando…";
con red y datos guardados → "No pudimos conectar…"; datos frescos → ningún aviso.

| Pieza | Flutter | Kotlin |
| --- | --- | --- |
| Estado de red en vivo | `connectivity_plus`: lectura inicial + `onConnectivityChanged` | `ConnectivityManager.registerDefaultNetworkCallback` como `callbackFlow<Boolean>` |
| Esperar a que la conexión se mantenga | `Timer` de 3 s, cancelado si se vuelve a caer | `distinctUntilChanged().collectLatest { if (!offline) { delay(3000); load() } }` |
| Enviar lo pendiente antes de leer | `getUserQuestsWithSource` sincroniza la cola primero | lo mismo en su repositorio |
| Sin red: no esperar al servidor | `NetworkGuard` falla de inmediato; timeout de 5 s | comprobar red antes de llamar; timeout de 5 s |
| Una sola carga a la vez | `load()` devuelve la carga en curso si la hay | un `Job` de carga: si está activo, no lanzar otro |

## Multithreading

`buildMissionHistory` es CPU pura: cruza intentos con el catálogo, normaliza
texto, filtra, ordena y agrupa. Se ejecuta **fuera del hilo principal** cada
vez que cambia el filtro o se hace una pausa al escribir. El historial nunca
se borra, así que ese trabajo crece con el uso, y se repite justo mientras el
teclado se anima. En segundo plano, la escritura y el scroll no se traban sin
importar el tamaño del historial.

| Paso | Flutter | Kotlin |
| --- | --- | --- |
| Leer catálogo, intentos y pasos | `async/await` del repositorio | `withContext(Dispatchers.IO)` |
| Calcular la bitácora | `compute(buildMissionHistory, input)` (isolate) | `withContext(Dispatchers.Default) { buildMissionHistory(input) }` |
| Esperar la pausa al escribir | `Timer` de 300 ms, reiniciado en cada tecla | `delay(300)` dentro del `Job`, que se cancela en cada tecla |
| Descartar un resultado viejo | contador de generación: si llega uno que ya no es el último, se ignora | `rebuildJob?.cancel()` antes de lanzar el nuevo (o `mapLatest`) |
| Pantalla cerrada a mitad del cálculo | el resultado se ignora | `viewModelScope` cancela solo |

- Un toque en un filtro se calcula **de inmediato** (sin esperar 300 ms) y
  usa el texto escrito hasta ese momento; la búsqueda que esperaba su pausa
  se cancela porque ya quedó incluida.
- La función debe ser pura: sin repositorio, sin Context, sin acceso a
  base de datos. Recibe datos simples y devuelve datos simples.

Esqueleto en Kotlin:

```kotlin
class MissionHistoryViewModel(
    private val questRepository: QuestRepository,
    private val userId: String,
) : ViewModel() {
    private val _state = MutableStateFlow(HistoryUiState())
    val state: StateFlow<HistoryUiState> = _state

    private var data = LoadedData()          // catálogo, intentos, pasos
    private var rebuildJob: Job? = null

    fun load() = viewModelScope.launch {
        data = withContext(Dispatchers.IO) { questRepository.loadHistoryData(userId) }
        rebuild(debounce = false)
    }

    fun setFilter(filter: HistoryFilter) {
        if (filter == _state.value.filter) return
        _state.update { it.copy(filter = filter) }
        rebuild(debounce = false)
    }

    fun setQuery(query: String) {
        _state.update { it.copy(query = query) }
        rebuild(debounce = true)
    }

    private fun rebuild(debounce: Boolean) {
        rebuildJob?.cancel()                 // la búsqueda anterior pierde
        rebuildJob = viewModelScope.launch {
            if (debounce) delay(300)
            _state.update { it.copy(isUpdating = true) }
            val s = _state.value
            val history = withContext(Dispatchers.Default) {
                buildMissionHistory(MissionHistoryInput(data.catalog, data.userQuests, data.stepTotals, s.filter, s.query))
            }
            _state.update { it.copy(history = history, isUpdating = false) }
        }
    }
}
```

## Casos para comprobar la paridad

Datos de `test/core/mission_history_test.dart` (fechas locales, 2026):

| Intento | Misión | Estado | Fecha que cuenta | Extra |
| --- | --- | --- | --- | --- |
| uq-1 | cafe ("Café de especialidad", food, 45 min, Usaquén) | completed | 2 nov | ★5 |
| uq-2 | mural ("Murales del centro", art, 60 min, La Candelaria) | completed | 20 nov | — |
| uq-3 | yoga ("Yoga al amanecer", mindfulness, 20 min) | abandoned | 6 nov | too_far |
| uq-4 | cafe | in_progress | 22 nov (started_at) | — |
| uq-5 | yoga | completed | 31 oct | — |
| uq-6 | mural | skipped | — | no cuenta |
| uq-7 | deleted-quest (no está en el catálogo) | completed | 2 sep | — |

Resultados esperados:

| Entrada | Resultado |
| --- | --- |
| Todas, sin búsqueda | total 6; orden uq-4, uq-2, uq-3, uq-1, uq-5, uq-7; meses nov, oct, sep |
| Noviembre, pasos {uq-1: 1200, uq-3: 300} | 2 completadas, 1 abandonada, 1 en curso, 105 min, 1500 pasos |
| Octubre, mismos pasos | 20 min, pasos null |
| Completadas | uq-2, uq-1, uq-5, uq-7 (total sigue en 6) |
| Abandonadas | uq-3 |
| "CAFE" | uq-4, uq-1 |
| "candelaria" | uq-2 |
| "gastronomía" | uq-4, uq-1 |
| "bienestar" o "mindfulness" | uq-3, uq-5 |
| "especialidad usaquen" | uq-4, uq-1 |
| "usaquen murales" | ninguno |
| "cafe" + Completadas | uq-1 |
| "   " | los 6 |
| "deleted" | uq-7 |
| Abandonadas, pendientes {uq-3, uq-1, uq-6} | uq-3 marcada pendiente; conteo de pendientes 2 (uq-1 cuenta aunque no se muestre, uq-6 es skip) |
| `normalize("  Café   CON  Ñandú ")` | "cafe con nandu" |
