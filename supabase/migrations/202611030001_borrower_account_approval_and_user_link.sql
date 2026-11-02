alter table public.profiles
  drop constraint if exists profiles_account_status_check;
alter table public.profiles
  add constraint profiles_account_status_check
  check (account_status in ('pending', 'active', 'inactive'));

alter table public.borrowers
  drop constraint if exists borrowers_status_check;
alter table public.borrowers
  add constraint borrowers_status_check
  check (status in ('pending', 'active', 'inactive'));

alter table public.borrowers
  add column if not exists user_id uuid references auth.users(id) on delete set null;

with matched_borrowers as (
  select distinct on (u.id)
    u.id as user_id,
    b.borrower_id
  from auth.users u
  join public.borrowers b on lower(b.email) = lower(u.email)
  where u.email is not null and b.user_id is null
  order by u.id, b.borrower_id
)
update public.borrowers b
set user_id = m.user_id
from matched_borrowers m
where b.borrower_id = m.borrower_id;

create unique index if not exists borrowers_user_id_uidx
  on public.borrowers (user_id)
  where user_id is not null;

revoke update on public.profiles from anon, authenticated;
revoke update (role, account_status) on public.profiles from anon, authenticated;
revoke insert, update, delete on public.borrowers from anon, authenticated;

create table public.account_access_audit_log (
  id bigint generated always as identity primary key,
  account_id uuid references auth.users(id) on delete set null,
  actor_id uuid references public.profiles(id) on delete set null,
  decision text not null check (decision in ('approved', 'rejected')),
  before_values jsonb not null,
  after_values jsonb not null,
  changed_at timestamptz not null default now()
);

create index account_access_audit_log_changed_at_idx
  on public.account_access_audit_log (changed_at desc);

alter table public.account_access_audit_log enable row level security;
revoke all on public.account_access_audit_log from anon, authenticated;
grant select on public.account_access_audit_log to authenticated;

create policy "equipment managers read account access audit"
  on public.account_access_audit_log for select to authenticated
  using (public.is_equipment_manager_user());
create policy "account access audit is immutable"
  on public.account_access_audit_log for all to public
  using (false) with check (false);

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_display_name text;
  v_first_name text;
  v_last_name text;
  v_department text;
  v_course text;
  v_gender text;
begin
  if new.id is null or new.email is null then
    raise exception 'A valid auth user is required to create an equipment account.';
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

  return new;
end;
$$;
revoke all on function public.create_profile_for_new_user() from public, anon, authenticated;

create or replace function public.current_borrower_id()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select b.borrower_id
  from public.borrowers b
  join public.profiles p on p.id = b.user_id
  join auth.users u on u.id = b.user_id
  where (select auth.uid()) is not null
    and b.user_id = (select auth.uid())
    and b.status = 'active'
    and p.role = 'staff'
    and p.account_status = 'active'
    and u.email_confirmed_at is not null
  order by b.borrower_id
  limit 1;
$$;
revoke all on function public.current_borrower_id() from public, anon;
grant execute on function public.current_borrower_id() to authenticated;

drop policy if exists "read own profile and administrators" on public.profiles;
create policy "read own profile and managers"
  on public.profiles for select to authenticated
  using (
    id = (select auth.uid())
    or (public.is_verified_active_user() and public.is_equipment_manager_user())
  );

drop policy if exists "read verified borrower records" on public.borrowers;
create policy "read linked borrower records"
  on public.borrowers for select to authenticated
  using (
    public.is_verified_active_user()
    and (user_id = (select auth.uid()) or public.is_equipment_manager_user())
  );

create or replace function public.request_equipment_borrowing(
  p_equipment_id bigint,
  p_purpose text,
  p_destination text,
  p_expected_return_date timestamptz,
  p_quantity integer
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_borrower bigint;
  v_borrowing bigint;
  v_start_date date := current_date;
  v_end_date date := p_expected_return_date::date;
begin
  if v_user is null or not public.is_verified_active_user() then
    raise exception 'Sign in with a verified, active borrower account before requesting equipment.';
  end if;
  if not exists (
    select 1 from public.profiles p where p.id = v_user and p.role = 'staff'
  ) then
    raise exception 'Only borrower accounts can request equipment.';
  end if;
  v_borrower := public.current_borrower_id();
  if v_borrower is null then
    raise exception 'Your borrower account is pending approval or inactive.';
  end if;
  if p_quantity is null or p_quantity < 1 then
    raise exception 'Request at least one equipment unit.';
  end if;
  if nullif(trim(p_purpose), '') is null or nullif(trim(p_destination), '') is null then
    raise exception 'Purpose and destination are required.';
  end if;
  if p_expected_return_date is null or p_expected_return_date <= now() then
    raise exception 'Expected return must be in the future.';
  end if;

  perform 1
  from public.equipment e
  where e.equipment_id = p_equipment_id
    and e.deleted_at is null
    and e.availability_status not in ('maintenance', 'retired')
  for update;
  if not found then raise exception 'This equipment is not currently available.'; end if;
  if not public.equipment_period_has_capacity(
    p_equipment_id, v_start_date, v_end_date, p_quantity, null, null
  ) then
    raise exception 'There are not enough units available for the requested period.';
  end if;

  insert into public.borrowings (
    transaction_code, borrower_id, processed_by, purpose, destination, expected_return_date
  ) values (
    'BR-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
    v_borrower, v_user, trim(p_purpose), trim(p_destination), p_expected_return_date
  ) returning borrowing_id into v_borrowing;

  insert into public.borrowing_items (borrowing_id, equipment_id, item_status, quantity)
  values (v_borrowing, p_equipment_id, 'pending', p_quantity);
  return v_borrowing;
end;
$$;
revoke all on function public.request_equipment_borrowing(bigint, text, text, timestamptz, integer) from public, anon;
grant execute on function public.request_equipment_borrowing(bigint, text, text, timestamptz, integer) to authenticated;

create or replace function public.validate_equipment_request()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_request_count integer;
begin
  if v_user is null or not public.is_verified_active_user() then
    raise exception 'Sign in with a verified, active account before submitting a request.';
  end if;
  if not exists (
    select 1 from public.profiles p where p.id = v_user and p.role = 'staff'
  ) or public.current_borrower_id() is null then
    raise exception 'Your borrower account must be approved before requesting equipment.';
  end if;
  if nullif(trim(new.purpose), '') is null or length(new.purpose) > 300 then
    raise exception 'Purpose must contain between 1 and 300 characters.';
  end if;
  if nullif(trim(new.destination), '') is null or length(new.destination) > 200 then
    raise exception 'Location must contain between 1 and 200 characters.';
  end if;

  if tg_table_name = 'reservations' then
    if new.requested_by is distinct from v_user then
      raise exception 'Reservations can only be submitted for your own account.';
    end if;
  elsif not exists (
    select 1 from public.borrowers b
    where b.borrower_id = new.borrower_id
      and b.user_id = v_user
      and b.status = 'active'
  ) then
    raise exception 'Borrowing requests can only be submitted for your own approved borrower account.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user::text, 0));
  select count(*) into v_request_count
  from (
    select b.created_at
    from public.borrowings b
    join public.borrowers br on br.borrower_id = b.borrower_id
    where br.user_id = v_user and b.created_at >= now() - interval '10 minutes'
    union all
    select r.created_at
    from public.reservations r
    where r.requested_by = v_user and r.created_at >= now() - interval '10 minutes'
  ) recent_requests;
  if v_request_count >= 5 then
    raise exception 'You have submitted too many equipment requests. Wait 10 minutes before trying again.';
  end if;
  return new;
end;
$$;
revoke all on function public.validate_equipment_request() from public, anon, authenticated;

create or replace function public.review_borrower_access(p_user_id uuid, p_decision text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_profile_status text;
  v_borrower_status text;
  v_next_status text;
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only an administrator or property custodian can review pending accounts.';
  end if;
  if p_decision is null or p_decision not in ('approve', 'reject') then
    raise exception 'Choose approve or reject.';
  end if;

  select p.account_status into v_profile_status
  from public.profiles p where p.id = p_user_id for update;
  if not found then raise exception 'Account not found.'; end if;
  select b.status into v_borrower_status
  from public.borrowers b where b.user_id = p_user_id for update;
  if not found then raise exception 'Linked borrower record not found.'; end if;
  if v_profile_status <> 'pending' or v_borrower_status <> 'pending' then
    raise exception 'This account is no longer pending review.';
  end if;

  v_next_status := case when p_decision = 'approve' then 'active' else 'inactive' end;
  update public.profiles
  set account_status = v_next_status, updated_at = now()
  where id = p_user_id;
  update public.borrowers set status = v_next_status where user_id = p_user_id;

  insert into public.account_access_audit_log (
    account_id, actor_id, decision, before_values, after_values
  ) values (
    p_user_id, v_actor, case when p_decision = 'approve' then 'approved' else 'rejected' end,
    jsonb_build_object('account_status', v_profile_status, 'borrower_status', v_borrower_status),
    jsonb_build_object('account_status', v_next_status, 'borrower_status', v_next_status)
  );
end;
$$;
revoke all on function public.review_borrower_access(uuid, text) from public, anon;
grant execute on function public.review_borrower_access(uuid, text) to authenticated;

create or replace function public.set_profile_role(p_user_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_admin_user() then
    raise exception 'Only an administrator can change roles.';
  end if;
  if p_role is null or p_role not in ('admin', 'property_custodian', 'staff') then
    raise exception 'Choose a valid role.';
  end if;
  update public.profiles
  set role = p_role, updated_at = now()
  where id = p_user_id and account_status = 'active';
  if not found then
    raise exception 'An active profile was not found. Approve pending access before assigning a role.';
  end if;
end;
$$;
revoke all on function public.set_profile_role(uuid, text) from public, anon;
grant execute on function public.set_profile_role(uuid, text) to authenticated;

notify pgrst, 'reload schema';
