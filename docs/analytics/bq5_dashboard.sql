-- =============================================================================
-- Dashboard BQ5 — Personalized Quest Recommendation (Type 2)
--
-- "Given the user's available time, preferred level of social interaction,
--  interests, and previous quest interactions, which three available
--  Sidequests have the highest relevance for the current session?"
--
-- Seven read-only queries over the shared Supabase database, one per panel.
-- Each one is self-contained: in Supabase Studio, save each as its own SQL
-- snippet and add it to the "BQ5 Dashboard" report (see BQ5_DASHBOARD.md).
-- They only SELECT: nothing is created, changed or deleted.
--
-- Sources (same contract as Sidequests-Analytics/docs/EVENT_SCHEMA.md, written
-- by both Kotlin and Flutter):
--   * recommendation_shown   one row per quest of each list from the
--                            public.recommend_quests RPC; metadata.rank,
--                            metadata.batch_id, metadata.social_level_source
--   * recommendation_accepted / recommendation_skipped, linked to what was
--                            shown by user_id + session_id + quest_id (as BQ8/BQ9)
--   * public.quests, public.user_preferences, public.user_quests
--
-- Conventions shared by every query:
--   * A list is one RPC answer: metadata.batch_id, or session + second when a
--     client didn't send it (same fallback as BQ5_PERSONALIZED_RECOMMENDATION_SQL).
--   * Rank is metadata.rank; when missing, the order of the events in the list.
--   * A unique impression is one user + session + quest, so reloading the same
--     list doesn't inflate the rates (same rule as BQ9).
--   * Dates are shown in Bogotá time.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- [BQ5-1] Resumen  (chart: table / single row)
-- -----------------------------------------------------------------------------
with shown as (
  select
    ae.id,
    ae.user_id,
    ae.session_id,
    ae.quest_id,
    ae.occurred_at,
    ae.user_id::text || '|' || coalesce(ae.session_id::text, '-') || '|'
      || coalesce(ae.metadata->>'batch_id', date_trunc('second', ae.occurred_at)::text) as list_key
  from public.analytics_events ae
  where ae.event_type = 'recommendation_shown'
    and ae.quest_id is not null
),
impressions as (
  select distinct on (user_id, session_id, quest_id) *
  from shown
  order by user_id, session_id, quest_id, occurred_at
),
outcomes as (
  select
    i.*,
    exists (
      select 1 from public.analytics_events a
      where a.event_type = 'recommendation_accepted'
        and a.user_id = i.user_id
        and a.session_id is not distinct from i.session_id
        and a.quest_id = i.quest_id
        and a.occurred_at >= i.occurred_at
    ) as accepted,
    exists (
      select 1 from public.analytics_events a
      where a.event_type = 'recommendation_skipped'
        and a.user_id = i.user_id
        and a.session_id is not distinct from i.session_id
        and a.quest_id = i.quest_id
        and a.occurred_at >= i.occurred_at
    ) as skipped
  from impressions i
),
lists as (
  select list_key, count(distinct quest_id) as size
  from shown
  group by list_key
),
sessions as (
  select user_id, session_id, bool_or(accepted) as any_accepted
  from outcomes
  group by user_id, session_id
)
select
  (select count(*) from lists) as listas_mostradas,
  (select count(*) from sessions) as sesiones_con_recomendaciones,
  (select count(distinct user_id) from sessions) as usuarios,
  (select round(100.0 * count(*) filter (where size >= 3) / nullif(count(*), 0), 1) from lists)
    as pct_listas_con_3_misiones,
  (select count(*) from outcomes) as impresiones_unicas,
  (select round(100.0 * count(*) filter (where accepted) / nullif(count(*), 0), 1) from outcomes)
    as pct_impresiones_aceptadas,
  (select round(100.0 * count(*) filter (where skipped) / nullif(count(*), 0), 1) from outcomes)
    as pct_impresiones_descartadas,
  (select round(100.0 * count(*) filter (where any_accepted) / nullif(count(*), 0), 1) from sessions)
    as pct_sesiones_con_aceptacion,
  (select to_char(max(occurred_at) at time zone 'America/Bogota', 'YYYY-MM-DD HH24:MI') from shown)
    as ultima_lista_bogota;


-- -----------------------------------------------------------------------------
-- [BQ5-2] Respuesta de BQ5: el último top 3 de cada sesión  (chart: table)
-- The 15 most recent sessions, with the context each list was asked with and
-- what the user did with each recommendation.
-- -----------------------------------------------------------------------------
with shown as (
  select
    ae.id,
    ae.user_id,
    ae.session_id,
    ae.quest_id,
    ae.occurred_at,
    ae.available_minutes,
    ae.social_level,
    coalesce(ae.metadata->>'social_level_source', 'profile') as social_level_source,
    ae.location_mode,
    ae.user_id::text || '|' || coalesce(ae.session_id::text, '-') || '|'
      || coalesce(ae.metadata->>'batch_id', date_trunc('second', ae.occurred_at)::text) as list_key,
    case when ae.metadata->>'rank' ~ '^[0-9]+$' then (ae.metadata->>'rank')::int end as rank_reported
  from public.analytics_events ae
  where ae.event_type = 'recommendation_shown'
    and ae.quest_id is not null
),
ranked as (
  select
    s.*,
    coalesce(
      s.rank_reported,
      row_number() over (partition by s.list_key order by s.occurred_at, s.id)::int
    ) as rank_position,
    max(s.occurred_at) over (partition by s.list_key) as list_time
  from shown s
),
latest_list as (
  select distinct on (user_id, session_id) user_id, session_id, list_key, list_time
  from ranked
  order by user_id, session_id, list_time desc
),
recent_sessions as (
  select * from latest_list order by list_time desc limit 15
)
select
  to_char(rs.list_time at time zone 'America/Bogota', 'YYYY-MM-DD HH24:MI') as fecha_bogota,
  left(rs.user_id::text, 8) as usuario,
  left(coalesce(rs.session_id::text, '-'), 8) as sesion,
  r.rank_position as posicion,
  q.title as mision,
  q.category as categoria,
  q.duration_minutes as duracion_min,
  r.available_minutes as tiempo_disponible_min,
  r.social_level as nivel_social_pedido,
  q.social_level as nivel_social_mision,
  case r.social_level_source when 'session' then 'sesion' else 'perfil' end as fuente_nivel_social,
  r.location_mode as modo_ubicacion,
  case
    when exists (
      select 1 from public.analytics_events a
      where a.event_type = 'recommendation_accepted'
        and a.user_id = r.user_id
        and a.session_id is not distinct from r.session_id
        and a.quest_id = r.quest_id
        and a.occurred_at >= r.occurred_at
    ) then 'aceptada'
    when exists (
      select 1 from public.analytics_events a
      where a.event_type = 'recommendation_skipped'
        and a.user_id = r.user_id
        and a.session_id is not distinct from r.session_id
        and a.quest_id = r.quest_id
        and a.occurred_at >= r.occurred_at
    ) then 'descartada'
    else 'sin accion'
  end as resultado
from recent_sessions rs
join ranked r on r.list_key = rs.list_key
join public.quests q on q.id = r.quest_id
where r.rank_position between 1 and 3
order by rs.list_time desc, r.rank_position;


-- -----------------------------------------------------------------------------
-- [BQ5-3] Aceptación y descarte por posición  (chart: bar, x = posicion,
-- y = tasa_aceptacion_pct and tasa_descarte_pct)
-- If the ranking is relevant, position 1 should be accepted the most.
-- -----------------------------------------------------------------------------
with shown as (
  select
    ae.id,
    ae.user_id,
    ae.session_id,
    ae.quest_id,
    ae.occurred_at,
    ae.user_id::text || '|' || coalesce(ae.session_id::text, '-') || '|'
      || coalesce(ae.metadata->>'batch_id', date_trunc('second', ae.occurred_at)::text) as list_key,
    case when ae.metadata->>'rank' ~ '^[0-9]+$' then (ae.metadata->>'rank')::int end as rank_reported
  from public.analytics_events ae
  where ae.event_type = 'recommendation_shown'
    and ae.quest_id is not null
),
ranked as (
  select
    s.*,
    coalesce(
      s.rank_reported,
      row_number() over (partition by s.list_key order by s.occurred_at, s.id)::int
    ) as rank_position
  from shown s
),
impressions as (
  select distinct on (user_id, session_id, quest_id) *
  from ranked
  order by user_id, session_id, quest_id, occurred_at
),
outcomes as (
  select
    i.rank_position,
    exists (
      select 1 from public.analytics_events a
      where a.event_type = 'recommendation_accepted'
        and a.user_id = i.user_id
        and a.session_id is not distinct from i.session_id
        and a.quest_id = i.quest_id
        and a.occurred_at >= i.occurred_at
    ) as accepted,
    exists (
      select 1 from public.analytics_events a
      where a.event_type = 'recommendation_skipped'
        and a.user_id = i.user_id
        and a.session_id is not distinct from i.session_id
        and a.quest_id = i.quest_id
        and a.occurred_at >= i.occurred_at
    ) as skipped
  from impressions i
)
select
  '#' || rank_position as posicion,
  count(*) as impresiones_unicas,
  count(*) filter (where accepted) as aceptadas,
  count(*) filter (where skipped) as descartadas,
  round(100.0 * count(*) filter (where accepted) / count(*), 1) as tasa_aceptacion_pct,
  round(100.0 * count(*) filter (where skipped) / count(*), 1) as tasa_descarte_pct
from outcomes
where rank_position between 1 and 3
group by rank_position
order by rank_position;


-- -----------------------------------------------------------------------------
-- [BQ5-4] ¿Las recomendaciones respetan el contexto del usuario?
-- (chart: bar, x = criterio, y = pct_cumple)
-- One row per BQ5 input. Time and history are hard filters of
-- recommend_quests, so they should be 100%; social level, interests and
-- location mode add points, so higher is better but 100% isn't guaranteed.
-- Interests are the user's current ones (they aren't stored per event).
-- -----------------------------------------------------------------------------
with shown as (
  select
    ae.user_id,
    ae.session_id,
    ae.quest_id,
    ae.occurred_at,
    ae.available_minutes,
    ae.social_level,
    ae.location_mode
  from public.analytics_events ae
  where ae.event_type = 'recommendation_shown'
    and ae.quest_id is not null
),
impressions as (
  select distinct on (user_id, session_id, quest_id) *
  from shown
  order by user_id, session_id, quest_id, occurred_at
),
checks as (
  select
    case when i.available_minutes is null then null
         else q.duration_minutes <= i.available_minutes end as time_ok,
    case when i.social_level is null then null
         else q.social_level = i.social_level end as social_ok,
    case when up.user_id is null then null
         when coalesce(cardinality(up.interests), 0) = 0 then true
         else exists (
           select 1 from unnest(up.interests) as interest(value)
           where lower(interest.value) = lower(q.category)
              or lower(interest.value) = any(q.tags)
         ) end as interest_ok,
    case when i.location_mode is null then null
         when i.location_mode = 'all' then true
         else q.location_mode = i.location_mode end as location_ok,
    not exists (
      select 1 from public.user_quests uq
      where uq.user_id = i.user_id
        and uq.quest_id = i.quest_id
        and uq.status = 'completed'
        and uq.completed_at < i.occurred_at
    ) as history_ok
  from impressions i
  join public.quests q on q.id = i.quest_id
  left join public.user_preferences up on up.user_id = i.user_id
)
select criterio, evaluadas, cumplen, round(100.0 * cumplen / nullif(evaluadas, 0), 1) as pct_cumple
from (
  select 1 as orden, 'Cabe en el tiempo disponible' as criterio,
         count(time_ok) as evaluadas, count(*) filter (where time_ok) as cumplen
  from checks
  union all
  select 2, 'No repite misiones ya completadas', count(history_ok), count(*) filter (where history_ok)
  from checks
  union all
  select 3, 'Coincide con el nivel social pedido', count(social_ok), count(*) filter (where social_ok)
  from checks
  union all
  select 4, 'Coincide con los intereses', count(interest_ok), count(*) filter (where interest_ok)
  from checks
  union all
  select 5, 'Respeta el modo de ubicacion', count(location_ok), count(*) filter (where location_ok)
  from checks
) per_criterion
order by orden;


-- -----------------------------------------------------------------------------
-- [BQ5-5] Tendencia diaria, últimos 30 días  (chart: line, x = dia,
-- y = listas_mostradas, aceptadas, descartadas)
-- -----------------------------------------------------------------------------
with days as (
  select generate_series(
    (now() at time zone 'America/Bogota')::date - 29,
    (now() at time zone 'America/Bogota')::date,
    interval '1 day'
  )::date as dia
),
lists as (
  select
    ae.user_id::text || '|' || coalesce(ae.session_id::text, '-') || '|'
      || coalesce(ae.metadata->>'batch_id', date_trunc('second', ae.occurred_at)::text) as list_key,
    min(ae.occurred_at) as shown_at
  from public.analytics_events ae
  where ae.event_type = 'recommendation_shown'
    and ae.quest_id is not null
    and ae.occurred_at >= now() - interval '31 days'
  group by 1
),
lists_per_day as (
  select (shown_at at time zone 'America/Bogota')::date as dia, count(*) as listas
  from lists
  group by 1
),
decisions_per_day as (
  select
    (occurred_at at time zone 'America/Bogota')::date as dia,
    count(*) filter (where event_type = 'recommendation_accepted') as aceptadas,
    count(*) filter (where event_type = 'recommendation_skipped') as descartadas
  from public.analytics_events
  where event_type in ('recommendation_accepted', 'recommendation_skipped')
    and occurred_at >= now() - interval '31 days'
  group by 1
)
select
  d.dia,
  coalesce(l.listas, 0) as listas_mostradas,
  coalesce(e.aceptadas, 0) as aceptadas,
  coalesce(e.descartadas, 0) as descartadas
from days d
left join lists_per_day l on l.dia = d.dia
left join decisions_per_day e on e.dia = d.dia
order by d.dia;


-- -----------------------------------------------------------------------------
-- [BQ5-6] Misiones más recomendadas (top 10)  (chart: bar, x = mision,
-- y = impresiones_unicas and aceptadas)
-- -----------------------------------------------------------------------------
with shown as (
  select
    ae.id,
    ae.user_id,
    ae.session_id,
    ae.quest_id,
    ae.occurred_at,
    ae.user_id::text || '|' || coalesce(ae.session_id::text, '-') || '|'
      || coalesce(ae.metadata->>'batch_id', date_trunc('second', ae.occurred_at)::text) as list_key,
    case when ae.metadata->>'rank' ~ '^[0-9]+$' then (ae.metadata->>'rank')::int end as rank_reported
  from public.analytics_events ae
  where ae.event_type = 'recommendation_shown'
    and ae.quest_id is not null
),
ranked as (
  select
    s.*,
    coalesce(
      s.rank_reported,
      row_number() over (partition by s.list_key order by s.occurred_at, s.id)::int
    ) as rank_position
  from shown s
),
impressions as (
  select distinct on (user_id, session_id, quest_id) *
  from ranked
  order by user_id, session_id, quest_id, occurred_at
),
outcomes as (
  select
    i.quest_id,
    i.rank_position,
    exists (
      select 1 from public.analytics_events a
      where a.event_type = 'recommendation_accepted'
        and a.user_id = i.user_id
        and a.session_id is not distinct from i.session_id
        and a.quest_id = i.quest_id
        and a.occurred_at >= i.occurred_at
    ) as accepted
  from impressions i
)
select
  q.title as mision,
  q.category as categoria,
  count(*) as impresiones_unicas,
  count(*) filter (where o.accepted) as aceptadas,
  round(100.0 * count(*) filter (where o.accepted) / count(*), 1) as tasa_aceptacion_pct,
  round(avg(o.rank_position), 2) as posicion_promedio
from outcomes o
join public.quests q on q.id = o.quest_id
group by q.id, q.title, q.category
order by impresiones_unicas desc, aceptadas desc, q.title
limit 10;


-- -----------------------------------------------------------------------------
-- [BQ5-7] Con qué contexto se pidieron las recomendaciones
-- (chart: bar, x = nivel_social, y = listas)
-- One row per social level and where it came from: the profile, or the
-- session-only "¿Cómo te sientes hoy?" override (Flutter).
-- -----------------------------------------------------------------------------
with lists as (
  select distinct on (list_key)
    list_key,
    social_level,
    social_level_source,
    available_minutes,
    location_mode
  from (
    select
      ae.user_id::text || '|' || coalesce(ae.session_id::text, '-') || '|'
        || coalesce(ae.metadata->>'batch_id', date_trunc('second', ae.occurred_at)::text) as list_key,
      ae.occurred_at,
      ae.social_level,
      coalesce(ae.metadata->>'social_level_source', 'profile') as social_level_source,
      ae.available_minutes,
      ae.location_mode
    from public.analytics_events ae
    where ae.event_type = 'recommendation_shown'
      and ae.quest_id is not null
  ) shown
  order by list_key, occurred_at
)
select
  coalesce(social_level, 'sin dato') as nivel_social,
  case social_level_source when 'session' then 'sesion (¿Como te sientes hoy?)' else 'perfil' end as fuente,
  count(*) as listas,
  round(avg(available_minutes)) as tiempo_disponible_promedio_min,
  count(*) filter (where location_mode = 'anywhere') as listas_sin_desplazamiento,
  count(*) filter (where location_mode = 'gps') as listas_cerca
from lists
group by 1, 2
order by listas desc, nivel_social;
