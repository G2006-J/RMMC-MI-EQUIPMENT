begin;

drop policy if exists "active users read own profile and managers" on public.profiles;
create policy "non-inactive users read own profile and managers"
  on public.profiles for select to authenticated
  using (
    (id = (select auth.uid()) and account_status <> 'inactive')
    or (public.is_verified_active_user() and public.is_equipment_manager_user())
  );

drop policy if exists "active users read own notifications" on public.notifications;
create policy "non-inactive users read own notifications"
  on public.notifications for select to authenticated
  using (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.account_status <> 'inactive'
    )
  );

drop policy if exists "active borrowers read own agreement acceptances" on public.borrower_agreement_acceptances;
create policy "non-inactive users read own agreement acceptances"
  on public.borrower_agreement_acceptances for select to authenticated
  using (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.account_status <> 'inactive'
    )
  );

create or replace function public.admin_anonymize_inactive_borrower(p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_account_status text;
  v_profile_photo_path text;
begin
  if v_actor is null or not public.is_verified_active_user()
    or not exists (
      select 1 from public.profiles p
      where p.id = v_actor and p.role = 'admin' and p.account_status = 'active'
    ) then
    raise exception 'Only an active administrator can anonymize a borrower.';
  end if;

  select p.account_status, p.profile_photo_path
    into v_account_status, v_profile_photo_path
  from public.profiles p where p.id = p_user_id for update;
  if not found then raise exception 'Account not found.'; end if;
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