create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  email text not null default '',
  department text not null default '',
  role text not null default 'member' check (role in ('member', 'manager', 'admin')),
  created_at timestamptz not null default now()
);

alter table public.profiles add column if not exists email text not null default '';

update public.profiles p
set email = coalesce(u.email, '')
from auth.users u
where p.id = u.id and p.email is distinct from coalesce(u.email, '');

create table if not exists public.equipment (
  id uuid primary key default gen_random_uuid(),
  asset_tag text not null unique,
  name text not null,
  category text not null,
  description text not null default '',
  location text not null default '',
  image_url text,
  status text not null default 'available' check (status in ('available', 'maintenance', 'retired')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.borrowings (
  id uuid primary key default gen_random_uuid(),
  equipment_id uuid not null references public.equipment(id) on delete restrict,
  borrower_id uuid not null references auth.users(id) on delete cascade,
  borrower_email text not null,
  purpose text not null check (length(trim(purpose)) > 0),
  location_of_use text not null check (length(trim(location_of_use)) > 0),
  start_date date not null,
  expected_return date not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'checked_out', 'return_requested', 'returned', 'rejected')),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  returned_at timestamptz,
  created_at timestamptz not null default now(),
  constraint borrowing_date_order check (expected_return >= start_date)
);

create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  equipment_id uuid not null references public.equipment(id) on delete restrict,
  requester_id uuid not null references auth.users(id) on delete cascade,
  requester_email text not null,
  purpose text not null check (length(trim(purpose)) > 0),
  location_of_use text not null check (length(trim(location_of_use)) > 0),
  start_date date not null,
  end_date date not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'cancelled', 'fulfilled', 'rejected')),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint reservation_date_order check (end_date >= start_date)
);

create index if not exists borrowings_borrower_created_idx on public.borrowings (borrower_id, created_at desc);
create index if not exists borrowings_equipment_status_dates_idx on public.borrowings (equipment_id, status, start_date, expected_return);
create index if not exists reservations_requester_created_idx on public.reservations (requester_id, created_at desc);
create index if not exists reservations_equipment_status_dates_idx on public.reservations (equipment_id, status, start_date, end_date);

create or replace function public.is_equipment_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and p.role in ('manager', 'admin')
  );
$$;

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, email)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), split_part(coalesce(new.email, ''), '@', 1)),
    coalesce(new.email, '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_equipment_profile on auth.users;
create trigger on_auth_user_created_equipment_profile
  after insert on auth.users
  for each row execute function public.create_profile_for_new_user();

alter table public.profiles enable row level security;
alter table public.equipment enable row level security;
alter table public.borrowings enable row level security;
alter table public.reservations enable row level security;

drop policy if exists "Members can read their profile" on public.profiles;
create policy "Members can read their profile"
  on public.profiles for select to authenticated
  using (id = (select auth.uid()) or public.is_equipment_admin());

drop policy if exists "Members can update their profile" on public.profiles;
create policy "Members can update their profile"
  on public.profiles for update to authenticated
  using (id = (select auth.uid()) or public.is_equipment_admin())
  with check (id = (select auth.uid()) or public.is_equipment_admin());

drop policy if exists "Authenticated members can read equipment" on public.equipment;
create policy "Authenticated members can read equipment"
  on public.equipment for select to authenticated
  using (true);

drop policy if exists "Managers can manage equipment" on public.equipment;
create policy "Managers can manage equipment"
  on public.equipment for all to authenticated
  using (public.is_equipment_admin())
  with check (public.is_equipment_admin());

drop policy if exists "Members can read their borrowing records" on public.borrowings;
create policy "Members can read their borrowing records"
  on public.borrowings for select to authenticated
  using (borrower_id = (select auth.uid()) or public.is_equipment_admin());

drop policy if exists "Members can read their reservations" on public.reservations;
create policy "Members can read their reservations"
  on public.reservations for select to authenticated
  using (requester_id = (select auth.uid()) or public.is_equipment_admin());

revoke all on public.profiles from anon, authenticated;
revoke all on public.equipment from anon, authenticated;
revoke all on public.borrowings from anon, authenticated;
revoke all on public.reservations from anon, authenticated;

grant select on public.profiles, public.equipment, public.borrowings, public.reservations to authenticated;
grant update (display_name, department) on public.profiles to authenticated;
grant insert, update, delete on public.equipment to authenticated;

create or replace function public.request_equipment(
  p_equipment_id uuid,
  p_purpose text,
  p_location text,
  p_start_date date,
  p_end_date date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_email text := (select auth.jwt() ->> 'email');
  v_status text;
  v_id uuid;
begin
  if v_user_id is null then
    raise exception 'Sign in before requesting equipment.';
  end if;
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception 'Choose a valid borrowing date range.';
  end if;
  if p_start_date < current_date then
    raise exception 'Borrowing requests must start today or later.';
  end if;
  if nullif(trim(p_purpose), '') is null or nullif(trim(p_location), '') is null then
    raise exception 'Purpose and location of use are required.';
  end if;

  select e.status into v_status
  from public.equipment e
  where e.id = p_equipment_id
  for update;

  if not found then
    raise exception 'Equipment was not found.';
  end if;
  if v_status <> 'available' then
    raise exception 'This equipment is not currently available.';
  end if;

  if exists (
    select 1 from public.borrowings b
    where b.equipment_id = p_equipment_id
      and b.status in ('pending', 'approved', 'checked_out', 'return_requested')
      and daterange(b.start_date, b.expected_return, '[]') && daterange(p_start_date, p_end_date, '[]')
  ) or exists (
    select 1 from public.reservations r
    where r.equipment_id = p_equipment_id
      and r.status in ('pending', 'approved')
      and daterange(r.start_date, r.end_date, '[]') && daterange(p_start_date, p_end_date, '[]')
  ) then
    raise exception 'This equipment already has a request for some or all of those dates.';
  end if;

  insert into public.borrowings (
    equipment_id, borrower_id, borrower_email, purpose, location_of_use, start_date, expected_return
  ) values (
    p_equipment_id, v_user_id, coalesce(v_email, ''), trim(p_purpose), trim(p_location), p_start_date, p_end_date
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.request_reservation(
  p_equipment_id uuid,
  p_purpose text,
  p_location text,
  p_start_date date,
  p_end_date date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_email text := (select auth.jwt() ->> 'email');
  v_status text;
  v_id uuid;
begin
  if v_user_id is null then
    raise exception 'Sign in before reserving equipment.';
  end if;
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception 'Choose a valid reservation date range.';
  end if;
  if p_start_date < current_date then
    raise exception 'Reservations must start today or later.';
  end if;
  if nullif(trim(p_purpose), '') is null or nullif(trim(p_location), '') is null then
    raise exception 'Purpose and location of use are required.';
  end if;

  select e.status into v_status
  from public.equipment e
  where e.id = p_equipment_id
  for update;

  if not found then
    raise exception 'Equipment was not found.';
  end if;
  if v_status <> 'available' then
    raise exception 'This equipment is not currently available for reservation.';
  end if;

  if exists (
    select 1 from public.borrowings b
    where b.equipment_id = p_equipment_id
      and b.status in ('pending', 'approved', 'checked_out', 'return_requested')
      and daterange(b.start_date, b.expected_return, '[]') && daterange(p_start_date, p_end_date, '[]')
  ) or exists (
    select 1 from public.reservations r
    where r.equipment_id = p_equipment_id
      and r.status in ('pending', 'approved')
      and daterange(r.start_date, r.end_date, '[]') && daterange(p_start_date, p_end_date, '[]')
  ) then
    raise exception 'This equipment already has a request for some or all of those dates.';
  end if;

  insert into public.reservations (
    equipment_id, requester_id, requester_email, purpose, location_of_use, start_date, end_date
  ) values (
    p_equipment_id, v_user_id, coalesce(v_email, ''), trim(p_purpose), trim(p_location), p_start_date, p_end_date
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.review_borrowing(p_borrowing_id uuid, p_action text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.borrowings%rowtype;
begin
  if not public.is_equipment_admin() then
    raise exception 'Only equipment managers can review borrowing requests.';
  end if;
  if p_action not in ('approve', 'reject') then
    raise exception 'Choose approve or reject.';
  end if;

  select * into v_row from public.borrowings where id = p_borrowing_id for update;
  if not found or v_row.status <> 'pending' then
    raise exception 'This borrowing request is no longer waiting for review.';
  end if;

  if p_action = 'approve' then
    perform 1 from public.equipment where id = v_row.equipment_id and status = 'available' for update;
    if not found then
      raise exception 'This equipment is no longer available.';
    end if;
    if exists (
      select 1 from public.borrowings b
      where b.equipment_id = v_row.equipment_id and b.id <> v_row.id
        and b.status in ('pending', 'approved', 'checked_out', 'return_requested')
        and daterange(b.start_date, b.expected_return, '[]') && daterange(v_row.start_date, v_row.expected_return, '[]')
    ) or exists (
      select 1 from public.reservations r
      where r.equipment_id = v_row.equipment_id and r.status in ('pending', 'approved')
        and daterange(r.start_date, r.end_date, '[]') && daterange(v_row.start_date, v_row.expected_return, '[]')
    ) then
      raise exception 'Another request conflicts with this date range.';
    end if;
  end if;

  update public.borrowings
  set status = case when p_action = 'approve' then 'approved' else 'rejected' end,
      reviewed_by = (select auth.uid()),
      reviewed_at = now()
  where id = v_row.id;
end;
$$;

create or replace function public.request_return(p_borrowing_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.borrowings%rowtype;
begin
  select * into v_row from public.borrowings where id = p_borrowing_id for update;
  if not found or (v_row.borrower_id <> (select auth.uid()) and not public.is_equipment_admin()) then
    raise exception 'Borrowing record was not found.';
  end if;
  if v_row.status not in ('approved', 'checked_out') then
    raise exception 'This item is not currently eligible for a return request.';
  end if;
  update public.borrowings set status = 'return_requested' where id = v_row.id;
end;
$$;

create or replace function public.complete_return(p_borrowing_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.borrowings%rowtype;
begin
  if not public.is_equipment_admin() then
    raise exception 'Only equipment managers can confirm returns.';
  end if;
  select * into v_row from public.borrowings where id = p_borrowing_id for update;
  if not found or v_row.status not in ('approved', 'checked_out', 'return_requested') then
    raise exception 'This item is not waiting to be returned.';
  end if;
  update public.borrowings set status = 'returned', returned_at = now() where id = v_row.id;
end;
$$;

create or replace function public.review_reservation(p_reservation_id uuid, p_action text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.reservations%rowtype;
begin
  if not public.is_equipment_admin() then
    raise exception 'Only equipment managers can review reservations.';
  end if;
  if p_action not in ('approve', 'reject') then
    raise exception 'Choose approve or reject.';
  end if;

  select * into v_row from public.reservations where id = p_reservation_id for update;
  if not found or v_row.status <> 'pending' then
    raise exception 'This reservation is no longer waiting for review.';
  end if;

  if p_action = 'approve' then
    perform 1 from public.equipment where id = v_row.equipment_id and status = 'available' for update;
    if not found then
      raise exception 'This equipment is no longer available.';
    end if;
    if exists (
      select 1 from public.borrowings b
      where b.equipment_id = v_row.equipment_id
        and b.status in ('pending', 'approved', 'checked_out', 'return_requested')
        and daterange(b.start_date, b.expected_return, '[]') && daterange(v_row.start_date, v_row.end_date, '[]')
    ) or exists (
      select 1 from public.reservations r
      where r.equipment_id = v_row.equipment_id and r.id <> v_row.id
        and r.status in ('pending', 'approved')
        and daterange(r.start_date, r.end_date, '[]') && daterange(v_row.start_date, v_row.end_date, '[]')
    ) then
      raise exception 'Another request conflicts with this date range.';
    end if;
  end if;

  update public.reservations
  set status = case when p_action = 'approve' then 'approved' else 'rejected' end,
      reviewed_by = (select auth.uid()),
      reviewed_at = now()
  where id = v_row.id;
end;
$$;

create or replace function public.set_member_role(p_user_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_equipment_admin() then
    raise exception 'Only an administrator can change member roles.';
  end if;
  if p_role not in ('member', 'manager', 'admin') then
    raise exception 'Choose a valid member role.';
  end if;
  update public.profiles set role = p_role where id = p_user_id;
  if not found then
    raise exception 'Member profile was not found.';
  end if;
end;
$$;

revoke all on function public.is_equipment_admin() from public, anon;
revoke all on function public.create_profile_for_new_user() from public, anon, authenticated;
revoke all on function public.request_equipment(uuid, text, text, date, date) from public, anon;
revoke all on function public.request_reservation(uuid, text, text, date, date) from public, anon;
revoke all on function public.review_borrowing(uuid, text) from public, anon;
revoke all on function public.request_return(uuid) from public, anon;
revoke all on function public.complete_return(uuid) from public, anon;
revoke all on function public.review_reservation(uuid, text) from public, anon;
revoke all on function public.set_member_role(uuid, text) from public, anon;

grant execute on function public.is_equipment_admin() to authenticated;
grant execute on function public.request_equipment(uuid, text, text, date, date) to authenticated;
grant execute on function public.request_reservation(uuid, text, text, date, date) to authenticated;
grant execute on function public.review_borrowing(uuid, text) to authenticated;
grant execute on function public.request_return(uuid) to authenticated;
grant execute on function public.complete_return(uuid) to authenticated;
grant execute on function public.review_reservation(uuid, text) to authenticated;
grant execute on function public.set_member_role(uuid, text) to authenticated;
