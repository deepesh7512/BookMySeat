-- Schedule trips from a departure time and the saved route segment durations.
create or replace function public.app_operator_create_trip(
  p_route_id uuid,
  p_journey_date date,
  p_departure_time time without time zone
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_trip_id uuid;
  v_bus_id uuid;
  v_bus_type text;
  v_operator_id uuid;
  v_master_id uuid;
  v_signature text;
  v_first_order integer;
  v_stop_count integer;
  v_total_minutes integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_departure_time is null then raise exception 'Set the bus departure time'; end if;

  select r.bus_id, b.bus_type, b.operator_id, coalesce(r.master_route_id, r.id)
    into v_bus_id, v_bus_type, v_operator_id, v_master_id
    from public.app_routes r
    join public.app_buses b on b.id = r.bus_id
    join public.app_operators o on o.id = b.operator_id
   where r.id = p_route_id and r.active and b.active and o.active
     and lower(o.email) = lower(auth.jwt() ->> 'email');
  if v_bus_id is null then raise exception 'Route or bus is inactive or not owned by this operator'; end if;
  if p_journey_date is null or p_journey_date < current_date then raise exception 'Journey date must be today or later'; end if;
  if exists (
    select 1 from public.app_trips
     where route_id = p_route_id and bus_id = v_bus_id and journey_date = p_journey_date
       and lower(coalesce(status, '')) <> 'cancelled'
  ) then raise exception 'This bus already has a trip on that route and date'; end if;

  select min(stop_order), count(*)::integer
    into v_first_order, v_stop_count
    from public.app_route_stops where route_id = p_route_id;
  if v_stop_count < 2 then raise exception 'Select at least two bus stoppages first'; end if;
  select coalesce(sum(segment_minutes), 0)::integer
    into v_total_minutes
    from public.app_route_stops
   where route_id = p_route_id and stop_order > v_first_order;
  if v_total_minutes <= 0 then raise exception 'Add travel times to the route stop segments before scheduling this trip'; end if;

  insert into public.app_trips(route_id, bus_id, journey_date, status)
  values (p_route_id, v_bus_id, p_journey_date, 'scheduled')
  returning id into v_trip_id;

  with timed_stops as (
    select s.*,
           sum(case when s.stop_order = v_first_order then 0 else coalesce(s.segment_minutes, 0) end)
             over (order by s.stop_order rows between unbounded preceding and current row)::integer as elapsed_minutes
      from public.app_route_stops s
     where s.route_id = p_route_id
  )
  insert into public.app_trip_stops(
    trip_id, original_stop_id, stop_order, stop_name, arrival_time, departure_time, distance_km, segment_minutes
  )
  select v_trip_id, s.id, s.stop_order, s.stop_name,
         (p_departure_time + make_interval(mins => s.elapsed_minutes))::time without time zone,
         (p_departure_time + make_interval(mins => s.elapsed_minutes))::time without time zone,
         s.distance_km, s.segment_minutes
    from timed_stops s
   order by s.stop_order;

  select string_agg(lower(trim(stop_name)), '|' order by stop_order)
    into v_signature
    from public.app_route_stops where route_id = v_master_id;
  insert into public.app_trip_fares(trip_id, boarding_stop_id, dropping_stop_id, fare)
  select v_trip_id, bs.id, ds.id, f.fare
    from public.app_route_type_fares f
    join public.app_trip_stops bs on bs.trip_id = v_trip_id
    join public.app_route_stops bsrc on bsrc.id = bs.original_stop_id
    join public.app_route_stops bmaster on bmaster.id = bsrc.master_stop_id
    join public.app_trip_stops ds on ds.trip_id = v_trip_id
    join public.app_route_stops dsrc on dsrc.id = ds.original_stop_id
    join public.app_route_stops dmaster on dmaster.id = dsrc.master_stop_id
   where f.operator_id = v_operator_id and f.route_signature = v_signature
     and lower(f.bus_type) = lower(trim(v_bus_type))
     and f.boarding_order = bmaster.stop_order and f.dropping_order = dmaster.stop_order;
  return v_trip_id;
end;
$function$;

-- Keep older app versions working while making segment duration authoritative.
create or replace function public.app_operator_create_trip(
  p_route_id uuid,
  p_journey_date date,
  p_departure_time time without time zone,
  p_final_arrival_time time without time zone
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
begin
  return public.app_operator_create_trip(p_route_id, p_journey_date, p_departure_time);
end;
$function$;

revoke all on function public.app_operator_create_trip(uuid, date, time without time zone) from public, anon;
revoke all on function public.app_operator_create_trip(uuid, date, time without time zone, time without time zone) from public, anon;
grant execute on function public.app_operator_create_trip(uuid, date, time without time zone) to authenticated;
grant execute on function public.app_operator_create_trip(uuid, date, time without time zone, time without time zone) to authenticated;

notify pgrst, 'reload schema';
