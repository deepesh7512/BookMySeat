-- Archive a shared route and its return direction without deleting route,
-- bus assignment, trip, fare, stop, or ticket history.
create or replace function public.app_admin_shared_route_archive(p_route_id uuid)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_return_id uuid;
begin
  if auth.uid() is null or not coalesce(public.app_is_admin(), false) then
    raise exception 'Admin access required';
  end if;

  select r.return_route_id
    into v_return_id
    from public.app_shared_routes r
   where r.id = p_route_id
   for update;

  if not found then
    raise exception 'Shared route not found';
  end if;

  -- Inactive shared routes disappear from the route catalog. Inactivate their
  -- bus assignments too, so operators cannot create new trips on archived routes.
  -- Existing app_trips and their trip/ticket records remain untouched.
  update public.app_shared_routes
     set active = false
   where id = any(array[p_route_id, v_return_id]);

  update public.app_routes
     set active = false
   where shared_route_id = any(array[p_route_id, v_return_id]);

  return true;
end;
$function$;

revoke all on function public.app_admin_shared_route_archive(uuid) from public, anon;
grant execute on function public.app_admin_shared_route_archive(uuid) to authenticated;
