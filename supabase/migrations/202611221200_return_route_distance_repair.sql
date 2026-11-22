-- Keep the Admin return-route RPC in sync with the master route's segment metrics,
-- then repair existing active return pairs created before synchronization ran.
create or replace function public.app_admin_shared_route_create_return(p_route_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null or not coalesce(public.app_is_admin(), false) then
    raise exception 'Admin access required';
  end if;

  perform public.app_shared_route_create_return(p_route_id => p_route_id);
  perform public.app_shared_route_sync_return(p_route_id);
  return true;
end;
$function$;

revoke all on function public.app_admin_shared_route_create_return(uuid) from public, anon;
grant execute on function public.app_admin_shared_route_create_return(uuid) to authenticated;

do $repair$
declare
  v_route record;
begin
  for v_route in
    select r.id
      from public.app_shared_routes r
     where r.active
       and r.return_route_id is not null
       and r.id < r.return_route_id
  loop
    perform public.app_shared_route_sync_return(v_route.id);
  end loop;
end;
$repair$;

notify pgrst, 'reload schema';
