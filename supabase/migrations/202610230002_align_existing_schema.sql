create extension if not exists pgcrypto;

alter table public.equipment
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by uuid references public.profiles(id);

create table if not exists public.equipment_audit_log (
  id bigint generated always as identity primary key,
  equipment_id bigint not null,
  asset_code text not null,
  action text not null check (action in ('insert', 'update', 'delete')),
  actor_id uuid references public.profiles(id) on delete set null,
  changed_fields text[] not null default '{}',
  old_values jsonb,
  new_values jsonb,
  changed_at timestamptz not null default now()
);

create index if not exists equipment_audit_log_changed_at_idx
  on public.equipment_audit_log (changed_at desc);

create table if not exists public.reservations (
  reservation_id bigint generated always as identity primary key,
  requested_by uuid not null references public.profiles(id) on delete cascade,
  borrower_id bigint not null references public.borrowers(borrower_id),
  equipment_id bigint not null references public.equipment(equipment_id),
  purpose text not null check (length(trim(purpose)) > 0),
  destination text not null check (length(trim(destination)) > 0),
  start_date date not null,
  end_date date not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled', 'fulfilled')),
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint reservation_date_order check (end_date >= start_date)
);

create index if not exists reservations_equipment_dates_idx
  on public.reservations (equipment_id, status, start_date, end_date);
create index if not exists reservations_requester_created_idx
  on public.reservations (requested_by, created_at desc);

create table if not exists public.return_requests (
  return_request_id bigint generated always as identity primary key,
  borrowing_id bigint not null references public.borrowings(borrowing_id) on delete cascade,
  requested_by uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'completed', 'rejected')),
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create unique index if not exists one_pending_return_request_per_borrowing
  on public.return_requests (borrowing_id) where status = 'pending';

create table if not exists public.feedback_threads (
  id bigint generated always as identity primary key,
  author_id uuid not null references public.profiles(id) on delete cascade,
  author_name text not null,
  title text not null check (length(trim(title)) > 0 and length(title) <= 140),
  category text not null default 'suggestion' check (category in ('suggestion', 'issue', 'question', 'other')),
  message text not null check (length(trim(message)) > 0 and length(message) <= 4000),
  status text not null default 'open' check (status in ('open', 'under_review', 'planned', 'implemented')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.feedback_replies (
  id bigint generated always as identity primary key,
  thread_id bigint not null references public.feedback_threads(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  author_name text not null,
  message text not null check (length(trim(message)) > 0 and length(message) <= 2000),
  created_at timestamptz not null default now()
);

create index if not exists feedback_threads_updated_idx on public.feedback_threads (updated_at desc);
create index if not exists feedback_replies_thread_created_idx on public.feedback_replies (thread_id, created_at);

create or replace function public.is_equipment_admin_user()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.role = 'admin'
      and p.account_status = 'active'
  );
$$;

create or replace function public.is_equipment_staff_user()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid())
      and p.role in ('admin', 'property_custodian')
      and p.account_status = 'active'
  );
$$;

create or replace function public.current_borrower_id()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select b.borrower_id
  from public.borrowers b
  where lower(b.email) = lower((select auth.jwt() ->> 'email'))
    and b.status = 'active'
  order by b.borrower_id
  limit 1;
$$;

create or replace function public.log_equipment_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_fields text[];
  v_action text;
begin
  if tg_op = 'INSERT' then
    v_new := to_jsonb(new) - 'deleted_at' - 'deleted_by';
    insert into public.equipment_audit_log (equipment_id, asset_code, action, actor_id, changed_fields, new_values)
    values (new.equipment_id, new.asset_code, 'insert', (select auth.uid()),
      array['asset_code', 'equipment_name', 'category_id', 'brand', 'model', 'serial_number', 'description', 'storage_location', 'condition_status', 'availability_status'],
      v_new);
    return new;
  elsif tg_op = 'UPDATE' then
    v_old := to_jsonb(old) - 'deleted_at' - 'deleted_by';
    v_new := to_jsonb(new) - 'deleted_at' - 'deleted_by';
    select coalesce(array_agg(n.key order by n.key), '{}')
      into v_fields
      from jsonb_each(v_new) n
      join jsonb_each(v_old) o using (key)
      where n.value is distinct from o.value;
    if old.deleted_at is null and new.deleted_at is not null then
      v_action := 'delete';
      v_fields := array['deleted_at'];
    else
      v_action := 'update';
    end if;
    if cardinality(v_fields) > 0 then
      insert into public.equipment_audit_log (equipment_id, asset_code, action, actor_id, changed_fields, old_values, new_values)
      values (new.equipment_id, new.asset_code, v_action, (select auth.uid()), v_fields, v_old, v_new);
    end if;
    return new;
  end if;
  v_old := to_jsonb(old) - 'deleted_at' - 'deleted_by';
  insert into public.equipment_audit_log (equipment_id, asset_code, action, actor_id, changed_fields, old_values)
  values (old.equipment_id, old.asset_code, 'delete', (select auth.uid()),
    array['asset_code', 'equipment_name', 'category_id', 'brand', 'model', 'serial_number', 'description', 'storage_location', 'condition_status', 'availability_status'],
    v_old);
  return old;
end;
$$;

drop trigger if exists equipment_audit_trigger on public.equipment;
create trigger equipment_audit_trigger after insert or update or delete on public.equipment
for each row execute function public.log_equipment_change();

create or replace function public.delete_equipment(p_equipment_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_equipment_admin_user() then
    raise exception 'Only an administrator can remove equipment.';
  end if;
  if exists (
    select 1 from public.borrowing_items bi
    join public.borrowings b on b.borrowing_id = bi.borrowing_id
    where bi.equipment_id = p_equipment_id
      and b.transaction_status in ('pending', 'approved', 'borrowed')
  ) then
    raise exception 'Equipment with an active borrowing request cannot be removed.';
  end if;
  update public.equipment set deleted_at = now(), deleted_by = (select auth.uid())
  where equipment_id = p_equipment_id and deleted_at is null;
  if not found then raise exception 'Equipment was not found or is already removed.'; end if;
end;
$$;

create or replace function public.request_equipment_borrowing(
  p_equipment_id bigint,
  p_purpose text,
  p_destination text,
  p_expected_return_date timestamptz
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
  v_email text := (select auth.jwt() ->> 'email');
begin
  if v_user is null then raise exception 'Sign in before requesting equipment.'; end if;
  if not exists (select 1 from public.profiles p where p.id = v_user and p.account_status = 'active') then
    raise exception 'Your account is inactive.';
  end if;
  select b.borrower_id into v_borrower from public.borrowers b
  where lower(b.email) = lower(v_email) and b.status = 'active'
  order by b.borrower_id limit 1;
  if v_borrower is null then raise exception 'No active borrower record matches your signed-in email. Contact the equipment administrator.'; end if;
  if nullif(trim(p_purpose), '') is null or nullif(trim(p_destination), '') is null then
    raise exception 'Purpose and destination are required.';
  end if;
  if p_expected_return_date is null or p_expected_return_date <= now() then
    raise exception 'Expected return must be in the future.';
  end if;
  perform 1 from public.equipment e
  where e.equipment_id = p_equipment_id and e.deleted_at is null and e.availability_status = 'available'
  for update;
  if not found then raise exception 'This equipment is not currently available.'; end if;
  if exists (
    select 1 from public.borrowing_items bi join public.borrowings b using (borrowing_id)
    where bi.equipment_id = p_equipment_id
      and b.transaction_status in ('pending', 'approved', 'borrowed')
  ) then raise exception 'A borrowing request already exists for this equipment.'; end if;
  if exists (
    select 1 from public.reservations r
    where r.equipment_id = p_equipment_id and r.status in ('pending', 'approved')
      and r.start_date <= p_expected_return_date::date and r.end_date >= current_date
  ) then raise exception 'This equipment is reserved during the requested period.'; end if;

  insert into public.borrowings (transaction_code, borrower_id, processed_by, purpose, destination, expected_return_date)
  values ('BR-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
    v_borrower, v_user, trim(p_purpose), trim(p_destination), p_expected_return_date)
  returning borrowing_id into v_borrowing;
  insert into public.borrowing_items (borrowing_id, equipment_id, item_status)
  values (v_borrowing, p_equipment_id, 'pending');
  return v_borrowing;
end;
$$;

create or replace function public.review_borrowing_request(p_borrowing_id bigint, p_action text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
begin
  if not public.is_equipment_staff_user() then raise exception 'Only equipment staff can review borrowing requests.'; end if;
  if p_action not in ('approve', 'reject') then raise exception 'Choose approve or reject.'; end if;
  select transaction_status into v_status from public.borrowings
  where borrowing_id = p_borrowing_id for update;
  if not found or v_status <> 'pending' then raise exception 'This request is no longer pending.'; end if;
  if p_action = 'approve' then
    if exists (
      select 1 from public.borrowing_items bi join public.equipment e using (equipment_id)
      where bi.borrowing_id = p_borrowing_id and (e.deleted_at is not null or e.availability_status <> 'available')
    ) then raise exception 'One or more requested items are no longer available.'; end if;
    update public.borrowings set transaction_status = 'approved', approved_by = (select auth.uid()), approved_at = now()
    where borrowing_id = p_borrowing_id;
    update public.borrowing_items set item_status = 'issued', issued_at = now()
    where borrowing_id = p_borrowing_id;
    update public.equipment e set availability_status = 'borrowed'
    from public.borrowing_items bi
    where bi.borrowing_id = p_borrowing_id and bi.equipment_id = e.equipment_id;
  else
    update public.borrowings set transaction_status = 'rejected', approved_by = (select auth.uid()), approved_at = now()
    where borrowing_id = p_borrowing_id;
  end if;
end;
$$;

create or replace function public.request_equipment_return(p_borrowing_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.borrowings b
    where b.borrowing_id = p_borrowing_id
      and b.borrower_id = public.current_borrower_id()
      and b.transaction_status in ('approved', 'borrowed')
  ) then raise exception 'This borrowing is not eligible for a return request.'; end if;
  insert into public.return_requests (borrowing_id, requested_by)
  values (p_borrowing_id, (select auth.uid()));
end;
$$;

create or replace function public.complete_equipment_return(p_borrowing_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_equipment_staff_user() then raise exception 'Only equipment staff can confirm returns.'; end if;
  if not exists (
    select 1 from public.borrowings where borrowing_id = p_borrowing_id
      and transaction_status in ('approved', 'borrowed')
  ) then raise exception 'This borrowing is no longer active.'; end if;
  update public.borrowing_items set item_status = 'returned', returned_at = now()
  where borrowing_id = p_borrowing_id and item_status in ('issued', 'pending');
  update public.equipment e set availability_status = 'available'
  from public.borrowing_items bi
  where bi.borrowing_id = p_borrowing_id and bi.equipment_id = e.equipment_id
    and e.deleted_at is null;
  update public.borrowings set transaction_status = 'returned', updated_at = now()
  where borrowing_id = p_borrowing_id;
  update public.return_requests set status = 'completed', completed_at = now()
  where borrowing_id = p_borrowing_id and status = 'pending';
end;
$$;

create or replace function public.request_equipment_reservation(
  p_equipment_id bigint,
  p_purpose text,
  p_destination text,
  p_start_date date,
  p_end_date date
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_borrower bigint := public.current_borrower_id();
  v_id bigint;
begin
  if (select auth.uid()) is null then raise exception 'Sign in before reserving equipment.'; end if;
  if not exists (
    select 1 from public.profiles p where p.id = (select auth.uid()) and p.account_status = 'active'
  ) then raise exception 'Your account is inactive.'; end if;
  if v_borrower is null then raise exception 'No active borrower record matches your signed-in email. Contact the equipment administrator.'; end if;
  if p_start_date is null or p_end_date is null or p_start_date < current_date or p_end_date < p_start_date then
    raise exception 'Choose a valid future reservation date range.';
  end if;
  if nullif(trim(p_purpose), '') is null or nullif(trim(p_destination), '') is null then
    raise exception 'Purpose and destination are required.';
  end if;
  perform 1 from public.equipment e
  where e.equipment_id = p_equipment_id and e.deleted_at is null and e.availability_status = 'available'
  for update;
  if not found then raise exception 'This equipment is not available to reserve.'; end if;
  if exists (
    select 1 from public.reservations r
    where r.equipment_id = p_equipment_id and r.status in ('pending', 'approved')
      and daterange(r.start_date, r.end_date, '[]') && daterange(p_start_date, p_end_date, '[]')
  ) then raise exception 'This equipment already has a reservation for those dates.'; end if;
  if exists (
    select 1 from public.borrowings b join public.borrowing_items bi using (borrowing_id)
    where bi.equipment_id = p_equipment_id and b.transaction_status in ('pending', 'approved', 'borrowed')
      and daterange(b.request_date::date, b.expected_return_date::date, '[]') && daterange(p_start_date, p_end_date, '[]')
  ) then raise exception 'This equipment has a borrowing request for those dates.'; end if;
  insert into public.reservations (requested_by, borrower_id, equipment_id, purpose, destination, start_date, end_date)
  values ((select auth.uid()), v_borrower, p_equipment_id, trim(p_purpose), trim(p_destination), p_start_date, p_end_date)
  returning reservation_id into v_id;
  return v_id;
end;
$$;

create or replace function public.review_equipment_reservation(p_reservation_id bigint, p_action text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.reservations%rowtype;
begin
  if not public.is_equipment_staff_user() then raise exception 'Only equipment staff can review reservations.'; end if;
  if p_action not in ('approve', 'reject') then raise exception 'Choose approve or reject.'; end if;
  select * into v_row from public.reservations where reservation_id = p_reservation_id for update;
  if not found or v_row.status <> 'pending' then raise exception 'This reservation is no longer pending.'; end if;
  if p_action = 'approve' and exists (
    select 1 from public.borrowings b join public.borrowing_items bi using (borrowing_id)
    where bi.equipment_id = v_row.equipment_id and b.transaction_status in ('pending', 'approved', 'borrowed')
      and daterange(b.request_date::date, b.expected_return_date::date, '[]') && daterange(v_row.start_date, v_row.end_date, '[]')
  ) then raise exception 'A borrowing request conflicts with these dates.'; end if;
  update public.reservations set
    status = case when p_action = 'approve' then 'approved' else 'rejected' end,
    reviewed_by = (select auth.uid()), reviewed_at = now()
  where reservation_id = p_reservation_id;
end;
$$;

create or replace function public.set_profile_role(p_user_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_equipment_admin_user() then raise exception 'Only an administrator can change roles.'; end if;
  if p_role not in ('admin', 'property_custodian', 'staff') then raise exception 'Choose a valid role.'; end if;
  update public.profiles set role = p_role, updated_at = now() where id = p_user_id;
  if not found then raise exception 'Profile not found.'; end if;
end;
$$;

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, email)
  values (new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), split_part(coalesce(new.email, ''), '@', 1)),
    new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_equipment_profile on auth.users;
create trigger on_auth_user_created_equipment_profile after insert on auth.users
for each row execute function public.create_profile_for_new_user();

create or replace function public.touch_feedback_thread()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.bump_feedback_thread_on_reply()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.feedback_threads set updated_at = now() where id = new.thread_id;
  return new;
end;
$$;

drop trigger if exists feedback_thread_updated_at on public.feedback_threads;
create trigger feedback_thread_updated_at before update on public.feedback_threads
for each row execute function public.touch_feedback_thread();
drop trigger if exists feedback_reply_bump_thread on public.feedback_replies;
create trigger feedback_reply_bump_thread after insert on public.feedback_replies
for each row execute function public.bump_feedback_thread_on_reply();

alter table public.profiles enable row level security;
alter table public.equipment enable row level security;
alter table public.categories enable row level security;
alter table public.borrowers enable row level security;
alter table public.borrowings enable row level security;
alter table public.borrowing_items enable row level security;
alter table public.reservations enable row level security;
alter table public.return_requests enable row level security;
alter table public.equipment_audit_log enable row level security;
alter table public.feedback_threads enable row level security;
alter table public.feedback_replies enable row level security;

do $$
declare
  p record;
begin
  for p in select tablename, policyname from pg_policies where schemaname = 'public' and tablename in
    ('profiles', 'equipment', 'categories', 'borrowers', 'borrowings', 'borrowing_items',
     'reservations', 'return_requests', 'equipment_audit_log', 'feedback_threads', 'feedback_replies')
  loop
    execute format('drop policy if exists %I on public.%I', p.policyname, p.tablename);
  end loop;
end;
$$;

create policy "read own profile and staff profiles" on public.profiles for select to authenticated
using (id = (select auth.uid()) or public.is_equipment_staff_user());
create policy "update own profile name" on public.profiles for update to authenticated
using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy "authenticated read active equipment" on public.equipment for select to authenticated
using (deleted_at is null);
create policy "admins manage equipment" on public.equipment for all to authenticated
using (public.is_equipment_admin_user()) with check (public.is_equipment_admin_user());
create policy "authenticated read categories" on public.categories for select to authenticated using (true);
create policy "read borrower records" on public.borrowers for select to authenticated
using (lower(email) = lower((select auth.jwt() ->> 'email')) or public.is_equipment_staff_user());
create policy "read relevant borrowings" on public.borrowings for select to authenticated
using (borrower_id = public.current_borrower_id() or public.is_equipment_staff_user());
create policy "read relevant borrowing items" on public.borrowing_items for select to authenticated
using (exists (
  select 1 from public.borrowings b where b.borrowing_id = borrowing_items.borrowing_id
    and (b.borrower_id = public.current_borrower_id() or public.is_equipment_staff_user())
));
create policy "read relevant reservations" on public.reservations for select to authenticated
using (requested_by = (select auth.uid()) or public.is_equipment_staff_user());
create policy "read relevant return requests" on public.return_requests for select to authenticated
using (requested_by = (select auth.uid()) or public.is_equipment_staff_user());
create policy "admins read equipment audit" on public.equipment_audit_log for select to authenticated
using (public.is_equipment_admin_user());
create policy "authenticated read feedback threads" on public.feedback_threads for select to authenticated using (true);
create policy "authenticated create feedback threads" on public.feedback_threads for insert to authenticated
with check (author_id = (select auth.uid()));
create policy "admins update feedback threads" on public.feedback_threads for update to authenticated
using (public.is_equipment_admin_user()) with check (public.is_equipment_admin_user());
create policy "authenticated read feedback replies" on public.feedback_replies for select to authenticated using (true);
create policy "authenticated create feedback replies" on public.feedback_replies for insert to authenticated
with check (author_id = (select auth.uid()));

revoke all on public.profiles, public.equipment, public.categories, public.borrowers, public.borrowings,
  public.borrowing_items, public.reservations, public.return_requests, public.equipment_audit_log,
  public.feedback_threads, public.feedback_replies from anon, authenticated;
grant select on public.profiles, public.equipment, public.categories, public.borrowers, public.borrowings,
  public.borrowing_items, public.reservations, public.return_requests, public.equipment_audit_log,
  public.feedback_threads, public.feedback_replies to authenticated;
grant insert, update, delete on public.equipment to authenticated;
grant update (full_name) on public.profiles to authenticated;
grant insert (author_id, author_name, title, category, message) on public.feedback_threads to authenticated;
grant update (status) on public.feedback_threads to authenticated;
grant insert (thread_id, author_id, author_name, message) on public.feedback_replies to authenticated;
grant usage, select on sequence public.equipment_equipment_id_seq,
  public.equipment_audit_log_id_seq,
  public.reservations_reservation_id_seq,
  public.return_requests_return_request_id_seq,
  public.feedback_threads_id_seq,
  public.feedback_replies_id_seq to authenticated;

revoke all on function public.is_equipment_admin_user() from public, anon;
revoke all on function public.is_equipment_staff_user() from public, anon;
revoke all on function public.current_borrower_id() from public, anon;
revoke all on function public.log_equipment_change() from public, anon, authenticated;
revoke all on function public.touch_feedback_thread() from public, anon, authenticated;
revoke all on function public.bump_feedback_thread_on_reply() from public, anon, authenticated;
revoke all on function public.create_profile_for_new_user() from public, anon, authenticated;
revoke all on function public.delete_equipment(bigint) from public, anon;
revoke all on function public.request_equipment_borrowing(bigint, text, text, timestamptz) from public, anon;
revoke all on function public.review_borrowing_request(bigint, text) from public, anon;
revoke all on function public.request_equipment_return(bigint) from public, anon;
revoke all on function public.complete_equipment_return(bigint) from public, anon;
revoke all on function public.request_equipment_reservation(bigint, text, text, date, date) from public, anon;
revoke all on function public.review_equipment_reservation(bigint, text) from public, anon;
revoke all on function public.set_profile_role(uuid, text) from public, anon;
grant execute on function public.is_equipment_admin_user() to authenticated;
grant execute on function public.is_equipment_staff_user() to authenticated;
grant execute on function public.current_borrower_id() to authenticated;
grant execute on function public.delete_equipment(bigint) to authenticated;
grant execute on function public.request_equipment_borrowing(bigint, text, text, timestamptz) to authenticated;
grant execute on function public.review_borrowing_request(bigint, text) to authenticated;
grant execute on function public.request_equipment_return(bigint) to authenticated;
grant execute on function public.complete_equipment_return(bigint) to authenticated;
grant execute on function public.request_equipment_reservation(bigint, text, text, date, date) to authenticated;
grant execute on function public.review_equipment_reservation(bigint, text) to authenticated;
grant execute on function public.set_profile_role(uuid, text) to authenticated;

notify pgrst, 'reload schema';
