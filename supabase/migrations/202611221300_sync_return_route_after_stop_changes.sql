-- Allow Admin Portal stop mutations to explicitly synchronize linked return routes.
create or replace function public.app_admin_sync_shared_route_return(p_route_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_sync_route_id uuid;
begin
  if auth.uid() is null or not coalesce(public.app_is_admin(), false) then
    raise exception 'Admin access required';
  end if;

  select case
           when route.return_route_id is not null then route.id
           else paired.id
         end
    into v_sync_route_id
    from public.app_shared_routes route
    left join public.app_shared_routes paired
      on paired.return_route_id = route.id and paired.active
   where route.id = p_route_id and route.active;

  if v_sync_route_id is null then
    raise exception 'Active shared route not found';
  end if;

  perform public.app_shared_route_sync_return(v_sync_route_id);
  return true;
end;
$function$;

revoke all on function public.app_admin_sync_shared_route_return(uuid) from public, anon;
grant execute on function public.app_admin_sync_shared_route_return(uuid) to authenticated;

notify pgrst, 'reload schema';