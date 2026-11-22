-- Keep paired return-route stops and fares synchronized in both directions.
-- Stop IDs remain stable so bus assignments and historical trips keep their links.

alter table public.app_shared_route_stops
  add column if not exists paired_stop_id uuid
  references public.app_shared_route_stops(id) on delete set null;

create unique index if not exists app_shared_route_stops_paired_stop_id_uidx
  on public.app_shared_route_stops(paired_stop_id)
  where paired_stop_id is not null;

-- Link the existing forward and reverse stops by opposite stop order.
do $migration$
declare
  v_route record;
  v_stop_count integer;
begin
  for v_route in
    select r.id as route_id, r.return_route_id
      from public.app_shared_routes r
     where r.return_route_id is not null
       and r.id < r.return_route_id
  loop
    select count(*)::integer into v_stop_count
      from public.app_shared_route_stops s where s.route_id = v_route.route_id;

    if v_stop_count = (select count(*) from public.app_shared_route_stops s where s.route_id = v_route.return_route_id) then
      update public.app_shared_route_stops source
         set paired_stop_id = reverse_stop.id
        from public.app_shared_route_stops reverse_stop
       where source.route_id = v_route.route_id
         and reverse_stop.route_id = v_route.return_route_id
         and reverse_stop.stop_order = v_stop_count + 1 - source.stop_order
         and source.paired_stop_id is null
         and reverse_stop.paired_stop_id is null;

      update public.app_shared_route_stops reverse_stop
         set paired_stop_id = source.id
        from public.app_shared_route_stops source
       where source.route_id = v_route.route_id
         and reverse_stop.route_id = v_route.return_route_id
         and reverse_stop.stop_order = v_stop_count + 1 - source.stop_order
         and source.paired_stop_id = reverse_stop.id
         and reverse_stop.paired_stop_id is null;
    end if;
  end loop;
end;
$migration$;

create or replace function public.app_shared_route_sync_return(p_route_id uuid)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_return_id uuid;
  v_stop_count integer;
  v_stop record;
  v_reverse_stop_id uuid;
begin
  select r.return_route_id into v_return_id
    from public.app_shared_routes r where r.id = p_route_id for update;
  if v_return_id is null then return true; end if;

  select count(*)::integer into v_stop_count
    from public.app_shared_route_stops s where s.route_id = p_route_id;

  -- Backfill any stops created by the legacy return-route function.
  for v_stop in
    select s.id, s.stop_order
      from public.app_shared_route_stops s
     where s.route_id = p_route_id and s.paired_stop_id is null
     order by s.stop_order
  loop
    select r.id into v_reverse_stop_id
      from public.app_shared_route_stops r
     where r.route_id = v_return_id
       and r.stop_order = v_stop_count + 1 - v_stop.stop_order
       and r.paired_stop_id is null
     limit 1;
    if v_reverse_stop_id is not null then
      update public.app_shared_route_stops set paired_stop_id = v_reverse_stop_id where id = v_stop.id;
      update public.app_shared_route_stops set paired_stop_id = v_stop.id where id = v_reverse_stop_id;
    end if;
  end loop;

  -- Move existing reverse orders out of the way before applying the mirrored order.
  update public.app_shared_route_stops
     set stop_order = stop_order + 1000000
   where route_id = v_return_id;

  -- Create a reverse stop for each newly added source stop and link both IDs.
  for v_stop in
    select s.id, s.stop_order, s.stop_name
      from public.app_shared_route_stops s
     where s.route_id = p_route_id and s.paired_stop_id is null
     order by s.stop_order
  loop
    insert into public.app_shared_route_stops(route_id, stop_order, stop_name, distance_km, segment_minutes, paired_stop_id)
    values(v_return_id, 2000000 + v_stop.stop_order, v_stop.stop_name, 0, 0, v_stop.id)
    returning id into v_reverse_stop_id;
    update public.app_shared_route_stops set paired_stop_id = v_reverse_stop_id where id = v_stop.id;
  end loop;

  -- Mirror names and reverse order. Segment metrics move to the paired stop
  -- immediately before it in the source direction (the same physical segment).
  update public.app_shared_route_stops reverse_stop
     set stop_name = source.stop_name,
         stop_order = v_stop_count + 1 - source.stop_order,
         distance_km = coalesce(next_source.distance_km, 0),
         segment_minutes = coalesce(next_source.segment_minutes, 0)
    from public.app_shared_route_stops source
    left join public.app_shared_route_stops next_source
      on next_source.route_id = source.route_id
     and next_source.stop_order = source.stop_order + 1
   where source.route_id = p_route_id
     and reverse_stop.route_id = v_return_id
     and source.paired_stop_id = reverse_stop.id;

  -- Mirror every fare with its boarding and destination stops reversed.
  delete from public.app_shared_route_fares reverse_fare
   where reverse_fare.route_id = v_return_id
     and not exists (
       select 1
         from public.app_shared_route_fares source_fare
         join public.app_shared_route_stops source_board on source_board.id = source_fare.boarding_stop_id
         join public.app_shared_route_stops source_drop on source_drop.id = source_fare.dropping_stop_id
        where source_fare.route_id = p_route_id
          and source_board.paired_stop_id = reverse_fare.dropping_stop_id
          and source_drop.paired_stop_id = reverse_fare.boarding_stop_id
          and source_fare.bus_type = reverse_fare.bus_type
     );

  insert into public.app_shared_route_fares(route_id, bus_type, boarding_stop_id, dropping_stop_id, fare)
  select v_return_id, source_fare.bus_type, source_drop.paired_stop_id, source_board.paired_stop_id, source_fare.fare
    from public.app_shared_route_fares source_fare
    join public.app_shared_route_stops source_board on source_board.id = source_fare.boarding_stop_id
    join public.app_shared_route_stops source_drop on source_drop.id = source_fare.dropping_stop_id
   where source_fare.route_id = p_route_id
     and source_board.paired_stop_id is not null
     and source_drop.paired_stop_id is not null
  on conflict(route_id, bus_type, boarding_stop_id, dropping_stop_id)
  do update set fare = excluded.fare, updated_at = now();

  perform public.app_shared_route_sync_assignments(v_return_id);
  return true;
end;
$function$;

create or replace function public.app_shared_route_save_stop(
  p_route_id uuid, p_stop_id uuid, p_stop_name text, p_stop_order integer,
  p_distance_km numeric, p_segment_minutes integer,
  p_arrival_time time without time zone, p_departure_time time without time zone
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id uuid;
  v_old_order integer;
  v_temp_order integer;
begin
  if not public.app_shared_route_is_editor() then raise exception 'Operator or admin access required'; end if;
  if not exists(select 1 from public.app_shared_routes where id = p_route_id and active) then raise exception 'Shared route not found'; end if;
  if trim(coalesce(p_stop_name, '')) = '' or p_stop_order < 1 or coalesce(p_distance_km, -1) < 0 or coalesce(p_segment_minutes, -1) < 0 then
    raise exception 'Enter a stop name, positive order, distance and segment time';
  end if;

  if p_stop_id is null then
    insert into public.app_shared_route_stops(route_id, stop_order, stop_name, distance_km, segment_minutes, arrival_time, departure_time)
    values(p_route_id, p_stop_order, trim(p_stop_name), p_distance_km, p_segment_minutes, p_arrival_time, p_departure_time)
    returning id into v_id;
  else
    select stop_order into v_old_order from public.app_shared_route_stops where id = p_stop_id and route_id = p_route_id;
    select coalesce(max(stop_order), 0) + 1 into v_temp_order from public.app_shared_route_stops where route_id = p_route_id;
    update public.app_shared_route_stops set stop_order = v_temp_order where id = p_stop_id and route_id = p_route_id;
    update public.app_shared_route_stops occupied
       set stop_order = v_old_order
      from public.app_shared_route_stops target
     where target.id = p_stop_id and target.route_id = p_route_id and target.stop_order = v_temp_order
       and occupied.route_id = p_route_id and occupied.stop_order = p_stop_order and occupied.id <> p_stop_id;
    update public.app_shared_route_stops
       set stop_order = p_stop_order, stop_name = trim(p_stop_name), distance_km = p_distance_km,
           segment_minutes = p_segment_minutes, arrival_time = p_arrival_time, departure_time = p_departure_time
     where id = p_stop_id and route_id = p_route_id returning id into v_id;
    if v_id is null then raise exception 'Route stop not found'; end if;
  end if;

  perform public.app_shared_route_sync_assignments(p_route_id);
  perform public.app_shared_route_sync_return(p_route_id);
  return v_id;
end;
$function$;

create or replace function public.app_shared_route_save_fare(
  p_route_id uuid, p_bus_type text, p_boarding_stop_id uuid, p_dropping_stop_id uuid, p_fare numeric
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_from integer;
  v_to integer;
  v_id uuid;
begin
  if not public.app_shared_route_is_editor() then raise exception 'Operator or admin access required'; end if;
  select stop_order into v_from from public.app_shared_route_stops where id = p_boarding_stop_id and route_id = p_route_id;
  select stop_order into v_to from public.app_shared_route_stops where id = p_dropping_stop_id and route_id = p_route_id;
  if p_bus_type not in ('Non AC Seater', 'Non AC Sleeper', 'AC Seater', 'AC Sleeper') or v_from is null or v_to is null or v_from >= v_to or p_fare is null or p_fare <= 0 then
    raise exception 'Choose a fare type, stops in travel order and a positive fare';
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

create or replace function public.app_shared_route_delete_fare(p_fare_id uuid)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_route_id uuid;
begin
  if not public.app_shared_route_is_editor() then raise exception 'Operator or admin access required'; end if;
  select route_id into v_route_id from public.app_shared_route_fares where id = p_fare_id;
  if v_route_id is null then raise exception 'Shared fare not found'; end if;
  delete from public.app_shared_route_fares where id = p_fare_id;
  perform public.app_shared_route_refresh_trip_fares(t.id)
    from public.app_trips t join public.app_routes r on r.id = t.route_id
   where r.shared_route_id = v_route_id and t.journey_date >= (now() at time zone 'Asia/Kolkata')::date
     and lower(coalesce(t.status, '')) not in ('cancelled', 'completed');
  perform public.app_shared_route_sync_return(v_route_id);
  return true;
end;
$function$;

create or replace function public.app_shared_route_delete_stop(p_stop_id uuid)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_pair_id uuid;
  v_route_id uuid;
  v_pair_route_id uuid;
begin
  if not public.app_shared_route_is_editor() then raise exception 'Operator or admin access required'; end if;
  select route_id, paired_stop_id into v_route_id, v_pair_id
    from public.app_shared_route_stops where id = p_stop_id for update;
  if v_route_id is null then raise exception 'Route stop not found'; end if;
  select route_id into v_pair_route_id from public.app_shared_route_stops where id = v_pair_id for update;

  if exists(
    select 1 from public.app_route_stops rs join public.app_trip_stops ts on ts.original_stop_id = rs.id
     where rs.shared_stop_id = any(array[p_stop_id, v_pair_id])
  ) then
    raise exception 'This stop is already used by a scheduled trip; edit it instead of deleting it';
  end if;

  delete from public.app_shared_route_fares f
   where f.boarding_stop_id = any(array[p_stop_id, v_pair_id])
      or f.dropping_stop_id = any(array[p_stop_id, v_pair_id]);
  delete from public.app_route_stops where shared_stop_id = any(array[p_stop_id, v_pair_id]);
  delete from public.app_shared_route_stops where id = any(array[p_stop_id, v_pair_id]);

  -- Compact both stop orders after deletion, then refresh their bus assignments.
  update public.app_shared_route_stops set stop_order = stop_order + 1000000 where route_id = v_route_id;
  with ordered as (
    select id, row_number() over(order by stop_order)::integer as new_order
      from public.app_shared_route_stops where route_id = v_route_id
  )
  update public.app_shared_route_stops s set stop_order = ordered.new_order from ordered where s.id = ordered.id;
  perform public.app_shared_route_sync_assignments(v_route_id);
  perform public.app_shared_route_sync_return(v_route_id);

  if v_pair_route_id is not null and v_pair_route_id <> v_route_id then
    perform public.app_shared_route_sync_assignments(v_pair_route_id);
  end if;
  return true;
end;
$function$;

create or replace function public.app_admin_shared_route_create_return(p_route_id uuid)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if auth.uid() is null or not coalesce(public.app_is_admin(), false) then raise exception 'Admin access required'; end if;
  perform public.app_shared_route_create_return(p_route_id => p_route_id);
  perform public.app_shared_route_sync_return(p_route_id);
  return true;
end;
$function$;

create or replace function public.app_admin_shared_route_remove_return(p_route_id uuid)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_return_id uuid;
begin
  if auth.uid() is null or not coalesce(public.app_is_admin(), false) then raise exception 'Admin access required'; end if;
  select return_route_id into v_return_id
    from public.app_shared_routes where id = p_route_id and active for update;
  if not found then raise exception 'Shared route not found'; end if;
  if v_return_id is null then raise exception 'This route has no return direction'; end if;

  update public.app_shared_routes set return_route_id = null where id = p_route_id;
  update public.app_shared_routes set return_route_id = null, active = false where id = v_return_id;
  update public.app_routes set active = false where shared_route_id = v_return_id;
  return true;
end;
$function$;

revoke all on function public.app_admin_shared_route_remove_return(uuid) from public, anon;
grant execute on function public.app_admin_shared_route_remove_return(uuid) to authenticated;

revoke all on function public.app_shared_route_sync_return(uuid) from public, anon, authenticated;
