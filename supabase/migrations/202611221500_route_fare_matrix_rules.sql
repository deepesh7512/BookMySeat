-- Rebuild shared route fares from the approved distance and bus-category rules.
alter table public.app_shared_route_fares
  drop constraint if exists app_shared_route_fares_bus_type_check;

alter table public.app_shared_route_fares
  add constraint app_shared_route_fares_bus_type_check
  check (bus_type in (
    'Non AC Seater', 'Non AC Sleeper', 'AC Seater', 'AC Sleeper',
    'Non AC Seater + Sleeper', 'AC Seater + Sleeper'
  ));

-- Keep the existing single-fare editor compatible with the current four bus types.
create or replace function public.app_shared_route_save_fare(
  p_route_id uuid, p_bus_type text, p_boarding_stop_id uuid, p_dropping_stop_id uuid, p_fare numeric
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_from integer;
  v_to integer;
  v_id uuid;
begin
  if not public.app_shared_route_is_editor() then raise exception 'Operator or admin access required'; end if;
  select stop_order into v_from from public.app_shared_route_stops where id = p_boarding_stop_id and route_id = p_route_id;
  select stop_order into v_to from public.app_shared_route_stops where id = p_dropping_stop_id and route_id = p_route_id;
  if p_bus_type not in (
      'Non AC Seater', 'Non AC Sleeper', 'AC Seater', 'AC Sleeper',
      'Non AC Seater + Sleeper', 'AC Seater + Sleeper'
    ) or v_from is null or v_to is null or v_from >= v_to or p_fare is null or p_fare < 10 or mod(p_fare, 10) <> 0 then
    raise exception 'Choose a fare type, stops in travel order and a fare of at least ₹10 in ₹10 increments';
  end if;
  insert into public.app_shared_route_fares(route_id, bus_type, boarding_stop_id, dropping_stop_id, fare)
  values(p_route_id, p_bus_type, p_boarding_stop_id, p_dropping_stop_id, p_fare)
  on conflict(route_id, bus_type, boarding_stop_id, dropping_stop_id)
  do update set fare = excluded.fare, updated_at = now()
  returning id into v_id;

  perform public.app_shared_route_refresh_trip_fares(t.id)
    from public.app_trips t join public.app_routes r on r.id = t.route_id
   where r.shared_route_id = p_route_id and t.journey_date >= (now() at time zone 'Asia/Kolkata')::date
     and lower(coalesce(t.status, '')) not in ('cancelled', 'completed');
  perform public.app_shared_route_sync_return(p_route_id);
  return v_id;
end;
$function$;

create or replace function public.app_shared_route_recalculate_fares(p_route_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_route_id uuid;
  v_return_id uuid;
begin
  select case
           when route.return_route_id is not null then route.id
           when paired.id is not null then paired.id
           else route.id
         end
    into v_route_id
    from public.app_shared_routes route
    left join public.app_shared_routes paired on paired.return_route_id = route.id and paired.active
   where route.id = p_route_id and route.active;
  if v_route_id is null then raise exception 'Active shared route not found'; end if;

  select return_route_id into v_return_id
    from public.app_shared_routes where id = v_route_id and active;

  with stop_pairs as (
    select origin.id as boarding_stop_id,
           destination.id as dropping_stop_id,
           coalesce(sum(segment.distance_km), 0)::numeric as distance_km
      from public.app_shared_route_stops origin
      join public.app_shared_route_stops destination
        on destination.route_id = origin.route_id and destination.stop_order > origin.stop_order
      join public.app_shared_route_stops segment
        on segment.route_id = origin.route_id
       and segment.stop_order > origin.stop_order
       and segment.stop_order <= destination.stop_order
     where origin.route_id = v_route_id
     group by origin.id, destination.id
  ), fare_rows as (
    select pair.boarding_stop_id,
           pair.dropping_stop_id,
           fare_type.bus_type,
           greatest(10, ceil((ceil((pair.distance_km * 2) / 10) * 10 * fare_type.multiplier) / 10) * 10)::numeric as fare
      from stop_pairs pair
      cross join (values
        ('Non AC Seater'::text, 1.00::numeric),
        ('Non AC Seater + Sleeper'::text, 1.25::numeric),
        ('AC Seater'::text, 1.50::numeric),
        ('AC Seater + Sleeper'::text, 1.50::numeric)
      ) as fare_type(bus_type, multiplier)
  )
  insert into public.app_shared_route_fares(route_id, bus_type, boarding_stop_id, dropping_stop_id, fare)
  select v_route_id, bus_type, boarding_stop_id, dropping_stop_id, fare from fare_rows
  on conflict(route_id, bus_type, boarding_stop_id, dropping_stop_id)
  do update set fare = excluded.fare, updated_at = now();

  -- Existing vehicles may still carry the legacy Non AC Sleeper / AC Sleeper labels.
  with stop_pairs as (
    select origin.id as boarding_stop_id,
           destination.id as dropping_stop_id,
           coalesce(sum(segment.distance_km), 0)::numeric as distance_km
      from public.app_shared_route_stops origin
      join public.app_shared_route_stops destination
        on destination.route_id = origin.route_id and destination.stop_order > origin.stop_order
      join public.app_shared_route_stops segment
        on segment.route_id = origin.route_id
       and segment.stop_order > origin.stop_order
       and segment.stop_order <= destination.stop_order
     where origin.route_id = v_route_id
     group by origin.id, destination.id
  ), legacy_fares as (
    select fare.id,
           greatest(10, ceil((ceil((pair.distance_km * 2) / 10) * 10 *
             case fare.bus_type when 'Non AC Sleeper' then 1.40::numeric else 1.75::numeric end) / 10) * 10)::numeric as amount
      from public.app_shared_route_fares fare
      join stop_pairs pair
        on pair.boarding_stop_id = fare.boarding_stop_id
       and pair.dropping_stop_id = fare.dropping_stop_id
     where fare.route_id = v_route_id
       and fare.bus_type in ('Non AC Sleeper', 'AC Sleeper')
  )
  update public.app_shared_route_fares fare
     set fare = legacy_fares.amount, updated_at = now()
    from legacy_fares
   where fare.id = legacy_fares.id;

  delete from public.app_shared_route_fares fare
   where fare.route_id = v_route_id
     and not exists (
       select 1 from public.app_shared_route_stops origin
       join public.app_shared_route_stops destination
         on destination.route_id = origin.route_id and destination.stop_order > origin.stop_order
       where origin.route_id = v_route_id
         and origin.id = fare.boarding_stop_id
         and destination.id = fare.dropping_stop_id
     );

  perform public.app_shared_route_sync_return(v_route_id);
  perform public.app_shared_route_refresh_trip_fares(trip.id)
    from public.app_trips trip
    join public.app_routes route on route.id = trip.route_id
   where route.shared_route_id = any(array_remove(array[v_route_id, v_return_id], null))
     and trip.journey_date >= (now() at time zone 'Asia/Kolkata')::date
     and lower(coalesce(trip.status, '')) not in ('cancelled', 'completed');

  return true;
end;
$function$;

create or replace function public.app_admin_recalculate_shared_route_fares(p_route_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null or not coalesce(public.app_is_admin(), false) then
    raise exception 'Admin access required';
  end if;
  return public.app_shared_route_recalculate_fares(p_route_id);
end;
$function$;

create or replace function public.app_admin_save_shared_route_fare_matrix(
  p_route_id uuid,
  p_boarding_stop_id uuid,
  p_dropping_stop_id uuid,
  p_fares jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_from integer;
  v_to integer;
  v_type record;
  v_fare numeric;
  v_return_id uuid;
  v_saved integer := 0;
begin
  if auth.uid() is null or not coalesce(public.app_is_admin(), false) then
    raise exception 'Admin access required';
  end if;
  select stop_order into v_from from public.app_shared_route_stops where id = p_boarding_stop_id and route_id = p_route_id;
  select stop_order into v_to from public.app_shared_route_stops where id = p_dropping_stop_id and route_id = p_route_id;
  if v_from is null or v_to is null or v_from >= v_to then
    raise exception 'Choose boarding and destination stops in travel order';
  end if;
  if jsonb_typeof(p_fares) <> 'object' then raise exception 'Fare values are required'; end if;

  select return_route_id into v_return_id from public.app_shared_routes where id = p_route_id and active;
  for v_type in select * from (values
    ('Non AC Seater'::text, 'non_ac_seater'::text),
    ('Non AC Seater + Sleeper'::text, 'non_ac_seater_sleeper'::text),
    ('AC Seater'::text, 'ac_seater'::text),
    ('AC Seater + Sleeper'::text, 'ac_seater_sleeper'::text)
  ) as types(bus_type, json_key)
  loop
    v_fare := nullif(p_fares ->> v_type.json_key, '')::numeric;
    if v_fare is null or v_fare < 10 or mod(v_fare, 10) <> 0 then
      raise exception 'Each fare must be at least ₹10 and a multiple of ₹10';
    end if;
    insert into public.app_shared_route_fares(route_id, bus_type, boarding_stop_id, dropping_stop_id, fare)
    values(p_route_id, v_type.bus_type, p_boarding_stop_id, p_dropping_stop_id, v_fare)
    on conflict(route_id, bus_type, boarding_stop_id, dropping_stop_id)
    do update set fare = excluded.fare, updated_at = now();
    v_saved := v_saved + 1;
  end loop;

  perform public.app_shared_route_sync_return(p_route_id);
  perform public.app_shared_route_refresh_trip_fares(trip.id)
    from public.app_trips trip
    join public.app_routes route on route.id = trip.route_id
   where route.shared_route_id = any(array_remove(array[p_route_id, v_return_id], null))
     and trip.journey_date >= (now() at time zone 'Asia/Kolkata')::date
     and lower(coalesce(trip.status, '')) not in ('cancelled', 'completed');
  return v_saved;
end;
$function$;

revoke all on function public.app_shared_route_recalculate_fares(uuid) from public, anon, authenticated;
revoke all on function public.app_admin_recalculate_shared_route_fares(uuid) from public, anon;
revoke all on function public.app_admin_save_shared_route_fare_matrix(uuid, uuid, uuid, jsonb) from public, anon;
grant execute on function public.app_admin_recalculate_shared_route_fares(uuid) to authenticated;
grant execute on function public.app_admin_save_shared_route_fare_matrix(uuid, uuid, uuid, jsonb) to authenticated;

-- Populate every forward stop pair and all four bus-category fares for active routes.
do $migration$
declare
  v_route record;
begin
  for v_route in
    select id from public.app_shared_routes where active and return_route_id is not null
    union all
    select id from public.app_shared_routes r
     where active and return_route_id is null
       and not exists(select 1 from public.app_shared_routes child where child.return_route_id = r.id)
  loop
    perform public.app_shared_route_recalculate_fares(v_route.id);
  end loop;
end;
$migration$;

notify pgrst, 'reload schema';
