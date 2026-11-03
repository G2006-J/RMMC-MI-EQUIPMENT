begin;

create or replace function public.admin_deactivate_borrower_account(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_account_status text;
  v_target_role text;
  v_active_admin_count integer;
begin
  if v_actor is null or not public.is_verified_active_user()
    or not exists (
      select 1 from public.profiles p
      where p.id = v_actor and p.role = 'admin' and p.account_status = 'active'
    ) then
    raise exception 'Only an active administrator can deactivate an account.';
  end if;
  if p_user_id = v_actor then raise exception 'An administrator cannot deactivate their own account.'; end if;

  perform pg_advisory_xact_lock(hashtextextended('phase8-admin-account-actions', 0));
  select p.account_status, p.role into v_account_status, v_target_role
  from public.profiles p where p.id = p_user_id for update;
  if not found then raise exception 'Account not found.'; end if;
  if v_target_role = 'admin' and v_account_status = 'active' then
    select count(*) into v_active_admin_count from public.profiles p
    where p.role = 'admin' and p.account_status = 'active';
    if v_active_admin_count <= 1 then raise exception 'The last active administrator cannot be deactivated.'; end if;
  end if;

  if v_account_status <> 'inactive' then
    update public.profiles set account_status = 'inactive', updated_at = now() where id = p_user_id;
  end if;
  update public.borrowers set status = 'inactive' where user_id = p_user_id;
  delete from auth.sessions where user_id = p_user_id;
end;
$$;
revoke all on function public.admin_deactivate_borrower_account(uuid) from public, anon, authenticated;
grant execute on function public.admin_deactivate_borrower_account(uuid) to authenticated;

create or replace function public.admin_anonymize_inactive_borrower(p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_account_status text;
  v_target_role text;
  v_profile_photo_path text;
  v_active_admin_count integer;
begin
  if v_actor is null or not public.is_verified_active_user()
    or not exists (
      select 1 from public.profiles p
      where p.id = v_actor and p.role = 'admin' and p.account_status = 'active'
    ) then
    raise exception 'Only an active administrator can anonymize a borrower.';
  end if;
  if p_user_id = v_actor then raise exception 'An administrator cannot anonymize their own account.'; end if;

  perform pg_advisory_xact_lock(hashtextextended('phase8-admin-account-actions', 0));
  select p.account_status, p.role, p.profile_photo_path
    into v_account_status, v_target_role, v_profile_photo_path
  from public.profiles p where p.id = p_user_id for update;
  if not found then raise exception 'Account not found.'; end if;
  if v_target_role = 'admin' and v_account_status = 'active' then
    select count(*) into v_active_admin_count from public.profiles p
    where p.role = 'admin' and p.account_status = 'active';
    if v_active_admin_count <= 1 then raise exception 'The last active administrator cannot be anonymized.'; end if;
  end if;
  if v_account_status <> 'inactive' then
    raise exception 'Deactivate the account before anonymizing its borrower record.';
  end if;
  if not exists (select 1 from public.borrowers b where b.user_id = p_user_id) then
    raise exception 'Linked borrower record not found.';
  end if;

  update public.profiles set
    full_name = 'Anonymized account', first_name = 'Anonymized', last_name = 'User',
    email = '', department = null, course = null, gender = null, profile_photo_path = null
  where id = p_user_id;
  update public.borrowers set
    first_name = 'Anonymized', middle_name = null, last_name = 'User', email = '',
    department = null, course = null, gender = null, profile_photo_path = null, status = 'inactive'
  where user_id = p_user_id;

  insert into public.phase7_audit_log (
    actor_id, source, event_type, entity_type, entity_id, before_values, after_values
  ) values (
    v_actor, 'rpc', 'borrower_personal_data_anonymized', 'profile', p_user_id::text, null, null
  );

  return v_profile_photo_path;
end;
$$;
revoke all on function public.admin_anonymize_inactive_borrower(uuid) from public, anon, authenticated;
grant execute on function public.admin_anonymize_inactive_borrower(uuid) to authenticated;

commit;