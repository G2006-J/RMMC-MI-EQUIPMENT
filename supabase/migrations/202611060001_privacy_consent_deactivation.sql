begin;

create table public.privacy_notice_acceptances (
  acceptance_id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  notice_version text not null check (length(trim(notice_version)) between 1 and 80),
  accepted_at timestamptz not null default now(),
  constraint privacy_notice_acceptances_user_version_key unique (user_id, notice_version)
);
alter table public.privacy_notice_acceptances enable row level security;
revoke all on public.privacy_notice_acceptances from public, anon, authenticated;
grant select on public.privacy_notice_acceptances to authenticated;
create policy "active users read own privacy notice acceptance"
  on public.privacy_notice_acceptances for select to authenticated
  using (user_id = (select auth.uid()) and public.is_verified_active_user());

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_display_name text;
  v_first_name text;
  v_last_name text;
  v_department text;
  v_course text;
  v_gender text;
begin
  if v_actor is not null then
    if v_actor <> new.id or coalesce((select auth.role()), '') <> 'authenticated' then
      raise exception 'Only the new authenticated account can create its profile.';
    end if;
  elsif session_user not in ('postgres', 'supabase_admin', 'supabase_auth_admin') then
    raise exception 'Only the trusted authentication workflow can create an account.';
  end if;
  if new.id is null or new.email is null then
    raise exception 'A valid auth user is required to create an equipment account.';
  end if;
  if new.raw_user_meta_data ->> 'privacy_consent' is distinct from 'true'
    or new.raw_user_meta_data ->> 'privacy_consent_version' is distinct from '2026-11-03-v1' then
    raise exception 'Accept the current privacy notice before creating an account.';
  end if;

  v_first_name := nullif(trim(new.raw_user_meta_data ->> 'first_name'), '');
  v_last_name := nullif(trim(new.raw_user_meta_data ->> 'last_name'), '');
  v_display_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(concat_ws(' ', v_first_name, v_last_name), ''),
    nullif(split_part(new.email, '@', 1), ''),
    'New User'
  );
  v_first_name := coalesce(v_first_name, nullif(split_part(v_display_name, ' ', 1), ''), 'Member');
  v_last_name := coalesce(
    v_last_name,
    nullif(trim(regexp_replace(v_display_name, '^\S+\s*', '')), ''),
    v_first_name
  );
  v_department := nullif(trim(new.raw_user_meta_data ->> 'department'), '');
  v_course := nullif(trim(new.raw_user_meta_data ->> 'course'), '');
  v_gender := nullif(trim(new.raw_user_meta_data ->> 'gender'), '');

  insert into public.profiles (
    id, full_name, first_name, last_name, email, department, course, gender, account_status
  ) values (
    new.id, concat_ws(' ', v_first_name, v_last_name), v_first_name, v_last_name,
    new.email, v_department, v_course, v_gender, 'pending'
  ) on conflict (id) do nothing;

  insert into public.borrowers (
    borrower_number, user_id, first_name, last_name, borrower_type, email,
    department, course, gender, status
  ) values (
    'AUTO-' || upper(replace(new.id::text, '-', '')),
    new.id, v_first_name, v_last_name, 'student', new.email,
    v_department, v_course, v_gender, 'pending'
  ) on conflict (borrower_number) do update set
    user_id = excluded.user_id,
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    email = excluded.email,
    department = excluded.department,
    course = excluded.course,
    gender = excluded.gender,
    status = 'pending';

  insert into public.privacy_notice_acceptances (user_id, notice_version)
  values (new.id, '2026-11-03-v1')
  on conflict (user_id, notice_version) do nothing;

  return new;
end;
$$;
revoke all on function public.create_profile_for_new_user() from public, anon, authenticated;

drop policy if exists "read own profile and managers" on public.profiles;
drop policy if exists "read own profile and administrators" on public.profiles;
create policy "active users read own profile and managers"
  on public.profiles for select to authenticated
  using (
    public.is_verified_active_user()
    and (id = (select auth.uid()) or public.is_equipment_manager_user())
  );

drop policy if exists "users read own notifications" on public.notifications;
create policy "active users read own notifications"
  on public.notifications for select to authenticated
  using (user_id = (select auth.uid()) and public.is_verified_active_user());

drop policy if exists "borrowers read own agreement acceptances" on public.borrower_agreement_acceptances;
create policy "active borrowers read own agreement acceptances"
  on public.borrower_agreement_acceptances for select to authenticated
  using (user_id = (select auth.uid()) and public.is_verified_active_user());

create or replace function public.admin_deactivate_borrower_account(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_account_status text;
begin
  if v_actor is null or not public.is_verified_active_user()
    or not exists (
      select 1 from public.profiles p
      where p.id = v_actor and p.role = 'admin' and p.account_status = 'active'
    ) then
    raise exception 'Only an active administrator can deactivate an account.';
  end if;

  select p.account_status into v_account_status
  from public.profiles p where p.id = p_user_id for update;
  if not found then raise exception 'Account not found.'; end if;

  if v_account_status <> 'inactive' then
    update public.profiles set account_status = 'inactive', updated_at = now()
    where id = p_user_id;
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

  return v_profile_photo_path;
end;
$$;
revoke all on function public.admin_anonymize_inactive_borrower(uuid) from public, anon, authenticated;
grant execute on function public.admin_anonymize_inactive_borrower(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;