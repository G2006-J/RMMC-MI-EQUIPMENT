begin;

drop policy if exists "Administrators can manage equipment" on public.equipment;
drop policy if exists "admins manage equipment" on public.equipment;
drop policy if exists "Managers can manage equipment" on public.equipment;
drop policy if exists "equipment managers manage equipment" on public.equipment;
create policy "administrators manage equipment"
  on public.equipment for all to authenticated
  using (public.is_equipment_admin_user())
  with check (public.is_equipment_admin_user());

drop policy if exists "admins upload equipment images" on storage.objects;
drop policy if exists "admins update equipment images" on storage.objects;
drop policy if exists "admins delete equipment images" on storage.objects;
drop policy if exists "equipment managers upload images" on storage.objects;
drop policy if exists "equipment managers update images" on storage.objects;
drop policy if exists "equipment managers delete images" on storage.objects;
create policy "admins upload equipment images"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'equipment-images' and public.is_equipment_admin_user());
create policy "admins update equipment images"
  on storage.objects for update to authenticated
  using (bucket_id = 'equipment-images' and public.is_equipment_admin_user())
  with check (bucket_id = 'equipment-images' and public.is_equipment_admin_user());
create policy "admins delete equipment images"
  on storage.objects for delete to authenticated
  using (bucket_id = 'equipment-images' and public.is_equipment_admin_user());

alter function public.convert_equipment_to_unit_tracking(bigint, jsonb)
  rename to convert_equipment_to_unit_tracking_internal;
revoke all on function public.convert_equipment_to_unit_tracking_internal(bigint, jsonb)
  from public, anon, authenticated;
create function public.convert_equipment_to_unit_tracking(p_equipment_id bigint, p_units jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_admin_user() then
    raise exception 'Only administrators can convert equipment to unit tracking.';
  end if;
  perform public.convert_equipment_to_unit_tracking_internal(p_equipment_id, p_units);
end;
$$;
revoke all on function public.convert_equipment_to_unit_tracking(bigint, jsonb) from public, anon;
grant execute on function public.convert_equipment_to_unit_tracking(bigint, jsonb) to authenticated;

create or replace function public.delete_equipment(p_equipment_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_admin_user() then
    raise exception 'Only administrators can remove equipment.';
  end if;
  if exists (
    select 1
    from public.borrowing_items bi
    join public.borrowings b on b.borrowing_id = bi.borrowing_id
    where bi.equipment_id = p_equipment_id
      and b.transaction_status in ('pending', 'approved', 'borrowed')
  ) then
    raise exception 'Equipment with an active borrowing request cannot be removed.';
  end if;
  update public.equipment
  set deleted_at = now(), deleted_by = (select auth.uid())
  where equipment_id = p_equipment_id and deleted_at is null;
  if not found then
    raise exception 'Equipment was not found or is already removed.';
  end if;
end;
$$;
revoke all on function public.delete_equipment(bigint) from public, anon;
grant execute on function public.delete_equipment(bigint) to authenticated;

create or replace function public.admin_update_profile_access_internal(
  p_user_id uuid,
  p_role text,
  p_account_status text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_current_role text;
  v_current_status text;
  v_next_status text;
  v_full_name text;
  v_email text;
  v_active_admin_count integer;
begin
  if v_actor is null or not public.is_verified_active_user()
    or not exists (
      select 1 from public.profiles p
      where p.id = v_actor and p.role = 'admin' and p.account_status = 'active'
    ) then
    raise exception 'Only an active administrator can change profile access.';
  end if;
  if p_role is null or p_role not in ('admin', 'property_custodian', 'staff')
    or (p_account_status is not null and p_account_status not in ('pending', 'active', 'inactive')) then
    raise exception 'Choose a valid role and account status.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('phase8-admin-account-actions', 0));
  if not public.is_verified_active_user()
    or not exists (
      select 1 from public.profiles p
      where p.id = v_actor and p.role = 'admin' and p.account_status = 'active'
    ) then
    raise exception 'Only an active administrator can change profile access.';
  end if;
  select p.role, p.account_status, p.full_name, p.email
    into v_current_role, v_current_status, v_full_name, v_email
  from public.profiles p
  where p.id = p_user_id
  for update;
  if not found then raise exception 'Profile not found.'; end if;
  if v_full_name = 'Anonymized account' and v_email = '' then
    raise exception 'Anonymized accounts cannot have their access changed.';
  end if;

  v_next_status := coalesce(p_account_status, v_current_status);
  if v_current_role = 'admin' and v_current_status = 'active'
    and (p_role <> 'admin' or v_next_status <> 'active') then
    select count(*) into v_active_admin_count
    from public.profiles p
    where p.role = 'admin' and p.account_status = 'active';
    if v_active_admin_count <= 1 then
      raise exception 'The last active administrator cannot be demoted or deactivated.';
    end if;
  end if;

  if p_user_id = v_actor
    and (p_role is distinct from v_current_role or v_next_status is distinct from v_current_status) then
    raise exception 'An administrator cannot change their own role or account status.';
  end if;

  update public.profiles
  set role = p_role, account_status = v_next_status, updated_at = now()
  where id = p_user_id;
  update public.borrowers
  set status = v_next_status
  where user_id = p_user_id;
end;
$$;
revoke all on function public.admin_update_profile_access_internal(uuid, text, text) from public, anon, authenticated;

create or replace function public.set_profile_role(p_user_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_target_status text;
begin
  if v_actor is null or not public.is_verified_active_user()
    or not exists (
      select 1 from public.profiles p
      where p.id = v_actor and p.role = 'admin' and p.account_status = 'active'
    ) then
    raise exception 'Only an active administrator can change roles.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('phase8-admin-account-actions', 0));
  select p.account_status into v_target_status
  from public.profiles p
  where p.id = p_user_id
  for update;
  if not found or v_target_status <> 'active' then
    raise exception 'An active profile was not found. Approve pending access before assigning a role.';
  end if;
  perform public.admin_update_profile_access_internal(p_user_id, p_role, null);
end;
$$;
revoke all on function public.set_profile_role(uuid, text) from public, anon;
grant execute on function public.set_profile_role(uuid, text) to authenticated;

create or replace function public.admin_update_profile_access(p_user_id uuid, p_role text, p_account_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
begin
  if v_actor is null or not public.is_verified_active_user()
    or not exists (
      select 1 from public.profiles p
      where p.id = v_actor and p.role = 'admin' and p.account_status = 'active'
    ) then
    raise exception 'Only an active administrator can change profile access.';
  end if;
  perform public.admin_update_profile_access_internal(p_user_id, p_role, p_account_status);
end;
$$;
revoke all on function public.admin_update_profile_access(uuid, text, text) from public, anon;
grant execute on function public.admin_update_profile_access(uuid, text, text) to authenticated;

create or replace function public.review_equipment_reservation(
  p_reservation_id bigint,
  p_action text,
  p_decline_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_reservation public.reservations%rowtype;
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can review reservations.';
  end if;
  if p_action is null or p_action not in ('approve', 'reject') then
    raise exception 'Choose approve or reject.';
  end if;
  if p_action = 'reject' and nullif(trim(p_decline_reason), '') is null then
    raise exception 'A reason is required to decline a reservation.';
  end if;

  perform e.equipment_id
  from public.equipment e
  join public.reservations r on r.equipment_id = e.equipment_id
  where r.reservation_id = p_reservation_id
  order by e.equipment_id
  for update of e;

  select r.* into v_reservation
  from public.reservations r
  where r.reservation_id = p_reservation_id
  for update;
  if not found or v_reservation.status <> 'pending' then
    raise exception 'This reservation is no longer pending.';
  end if;

  if p_action = 'approve' and not public.equipment_period_has_approval_capacity(
    v_reservation.equipment_id,
    v_reservation.start_date,
    v_reservation.end_date,
    v_reservation.quantity,
    null,
    v_reservation.reservation_id
  ) then
    raise exception 'The reserved amount is no longer available for the selected dates.';
  end if;

  update public.reservations
  set status = case when p_action = 'approve' then 'approved' else 'rejected' end,
      decline_reason = case when p_action = 'reject' then trim(p_decline_reason) else null end,
      reviewed_by = v_actor,
      reviewed_at = now()
  where reservation_id = p_reservation_id;
end;
$$;
revoke all on function public.review_equipment_reservation(bigint, text, text) from public, anon;
grant execute on function public.review_equipment_reservation(bigint, text, text) to authenticated;

create or replace function public.mark_reservation_picked_up(p_reservation_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can mark reservations as picked up.';
  end if;
  update public.reservations r
  set picked_up_at = now()
  from public.reservation_settings s
  where r.reservation_id = p_reservation_id
    and s.singleton
    and r.status = 'approved'
    and r.picked_up_at is null
    and now() <= ((r.start_date + r.start_time) at time zone current_setting('TimeZone'))
      + make_interval(mins => s.pickup_grace_period_minutes);
  if not found then
    raise exception 'Only approved reservations that have not expired can be marked as picked up.';
  end if;
end;
$$;
revoke all on function public.mark_reservation_picked_up(bigint) from public, anon;
grant execute on function public.mark_reservation_picked_up(bigint) to authenticated;

notify pgrst, 'reload schema';
commit;
