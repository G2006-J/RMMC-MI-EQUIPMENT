alter table public.borrowing_items
  add column if not exists quantity integer not null default 1;

alter table public.reservations
  add column if not exists quantity integer not null default 1,
  add column if not exists start_time time not null default time '09:00',
  add column if not exists end_time time not null default time '17:00';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'reservations_time_order'
      and conrelid = 'public.reservations'::regclass
  ) then
    alter table public.reservations
      add constraint reservations_time_order
      check (end_date > start_date or end_time > start_time);
  end if;
end;
$$;

create or replace function public.is_equipment_staff_user()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_equipment_manager_user();
$$;

create or replace function public.equipment_period_has_capacity(
  p_equipment_id bigint,
  p_start_date date,
  p_end_date date,
  p_requested_quantity integer,
  p_exclude_borrowing_id bigint default null,
  p_exclude_reservation_id bigint default null
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_quantity integer;
  v_status text;
begin
  if p_requested_quantity is null or p_requested_quantity < 1
    or p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    return false;
  end if;

  select e.quantity, e.availability_status
    into v_quantity, v_status
  from public.equipment e
  where e.equipment_id = p_equipment_id
    and e.deleted_at is null;

  if not found or v_quantity < p_requested_quantity or v_status in ('maintenance', 'retired') then
    return false;
  end if;

  return not exists (
    with active_periods as (
      select b.request_date::date as start_date,
             case
               when b.expected_return_date::date < current_date then 'infinity'::date
               else b.expected_return_date::date
             end as end_date,
             bi.quantity
      from public.borrowings b
      join public.borrowing_items bi using (borrowing_id)
      where bi.equipment_id = p_equipment_id
        and b.transaction_status in ('pending', 'approved', 'borrowed')
        and (p_exclude_borrowing_id is null or b.borrowing_id <> p_exclude_borrowing_id)
      union all
      select r.start_date, r.end_date, r.quantity
      from public.reservations r
      where r.equipment_id = p_equipment_id
        and r.status in ('pending', 'approved')
        and (p_exclude_reservation_id is null or r.reservation_id <> p_exclude_reservation_id)
    ),
    candidate_dates as (
      select p_start_date as occupied_on
      union
      select active.start_date
      from active_periods active
      where active.start_date > p_start_date
        and active.start_date <= p_end_date
    )
    select 1
    from candidate_dates candidate
    where (
      select coalesce(sum(active.quantity), 0)
      from active_periods active
      where active.start_date <= candidate.occupied_on
        and active.end_date >= candidate.occupied_on
    ) + p_requested_quantity > v_quantity
  );
end;
$$;

create or replace function public.equipment_period_has_capacity(
  p_equipment_id bigint,
  p_start_date date,
  p_end_date date
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.equipment_period_has_capacity(p_equipment_id, p_start_date, p_end_date, 1, null, null);
$$;

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
  v_email text := (select auth.jwt() ->> 'email');
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
  if p_quantity is null or p_quantity < 1 then
    raise exception 'Request at least one equipment unit.';
  end if;
  if nullif(trim(p_purpose), '') is null or nullif(trim(p_destination), '') is null then
    raise exception 'Purpose and destination are required.';
  end if;
  if p_expected_return_date is null or p_expected_return_date <= now() then
    raise exception 'Expected return must be in the future.';
  end if;

  select b.borrower_id into v_borrower
  from public.borrowers b
  where lower(b.email) = lower(v_email) and b.status = 'active'
  order by b.borrower_id
  limit 1;
  if v_borrower is null then
    raise exception 'No active borrower record matches your signed-in email. Contact the equipment administrator.';
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
  )
  values (
    'BR-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
    v_borrower, v_user, trim(p_purpose), trim(p_destination), p_expected_return_date
  )
  returning borrowing_id into v_borrowing;

  insert into public.borrowing_items (borrowing_id, equipment_id, item_status, quantity)
  values (v_borrowing, p_equipment_id, 'pending', p_quantity);
  return v_borrowing;
end;
$$;

create or replace function public.request_equipment_borrowing(
  p_equipment_id bigint,
  p_purpose text,
  p_destination text,
  p_expected_return_date timestamptz
)
returns bigint
language sql
security definer
set search_path = ''
as $$
  select public.request_equipment_borrowing(
    p_equipment_id, p_purpose, p_destination, p_expected_return_date, 1
  );
$$;

create or replace function public.request_equipment_reservation(
  p_equipment_id bigint,
  p_purpose text,
  p_destination text,
  p_start_date date,
  p_end_date date,
  p_quantity integer,
  p_start_time time,
  p_end_time time
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_borrower bigint := public.current_borrower_id();
  v_id bigint;
begin
  if v_user is null or not public.is_verified_active_user() then
    raise exception 'Sign in with a verified, active borrower account before reserving equipment.';
  end if;
  if not exists (
    select 1 from public.profiles p where p.id = v_user and p.role = 'staff'
  ) then
    raise exception 'Only borrower accounts can reserve equipment.';
  end if;
  if v_borrower is null then
    raise exception 'No active borrower record matches your signed-in email. Contact the equipment administrator.';
  end if;
  if p_quantity is null or p_quantity < 1 then
    raise exception 'Reserve at least one equipment unit.';
  end if;
  if p_start_date is null or p_end_date is null or p_start_time is null or p_end_time is null
    or p_start_date < current_date or p_end_date < p_start_date
    or (p_end_date = p_start_date and p_end_time <= p_start_time) then
    raise exception 'Choose a valid future reservation date range.';
  end if;
  if nullif(trim(p_purpose), '') is null or nullif(trim(p_destination), '') is null then
    raise exception 'Purpose and destination are required.';
  end if;

  perform 1
  from public.equipment e
  where e.equipment_id = p_equipment_id
    and e.deleted_at is null
    and e.availability_status not in ('maintenance', 'retired')
  for update;
  if not found then raise exception 'This equipment is not available to reserve.'; end if;
  if not public.equipment_period_has_capacity(
    p_equipment_id, p_start_date, p_end_date, p_quantity, null, null
  ) then
    raise exception 'There are not enough units available for the selected reservation dates.';
  end if;

  insert into public.reservations (
    requested_by, borrower_id, equipment_id, purpose, destination,
    start_date, end_date, quantity, start_time, end_time
  )
  values (
    v_user, v_borrower, p_equipment_id, trim(p_purpose), trim(p_destination),
    p_start_date, p_end_date, p_quantity, p_start_time, p_end_time
  )
  returning reservation_id into v_id;
  return v_id;
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
language sql
security definer
set search_path = ''
as $$
  select public.request_equipment_reservation(
    p_equipment_id, p_purpose, p_destination, p_start_date, p_end_date, 1, time '09:00', time '17:00'
  );
$$;

create or replace function public.request_equipment_reservation(
  p_equipment_id bigint,
  p_purpose text,
  p_destination text,
  p_start_date date,
  p_end_date date,
  p_quantity integer
)
returns bigint
language sql
security definer
set search_path = ''
as $$
  select public.request_equipment_reservation(
    p_equipment_id, p_purpose, p_destination, p_start_date, p_end_date,
    p_quantity, time '09:00', time '17:00'
  );
$$;

create or replace function public.review_borrowing_request(p_borrowing_id bigint, p_action text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request record;
begin
  if not public.is_equipment_staff_user() then
    raise exception 'Only administrators and property custodians can review borrowing requests.';
  end if;
  if p_action is null or p_action not in ('approve', 'reject') then raise exception 'Choose approve or reject.'; end if;

  perform 1
  from public.equipment e
  join public.borrowing_items bi on bi.equipment_id = e.equipment_id
  where bi.borrowing_id = p_borrowing_id
  for update of e;

  select b.borrowing_id, b.transaction_status, b.request_date, b.expected_return_date,
         bi.equipment_id, bi.quantity, e.deleted_at, e.availability_status, e.quantity as inventory_quantity
    into v_request
  from public.borrowings b
  join public.borrowing_items bi using (borrowing_id)
  join public.equipment e using (equipment_id)
  where b.borrowing_id = p_borrowing_id
  for update of b;
  if not found or v_request.transaction_status <> 'pending' then
    raise exception 'This request is no longer pending.';
  end if;

  if p_action = 'approve' and (
    v_request.deleted_at is not null
    or v_request.availability_status in ('maintenance', 'retired')
    or not public.equipment_period_has_capacity(
      v_request.equipment_id,
      v_request.request_date::date,
      v_request.expected_return_date::date,
      v_request.quantity,
      v_request.borrowing_id,
      null
    )
  ) then
    raise exception 'The requested amount is no longer available.';
  end if;

  if p_action = 'approve' then
    update public.borrowings
    set transaction_status = 'approved', approved_by = (select auth.uid()), approved_at = now()
    where borrowing_id = p_borrowing_id;
    update public.borrowing_items
    set item_status = 'issued', issued_at = now()
    where borrowing_id = p_borrowing_id;
  else
    update public.borrowings
    set transaction_status = 'rejected', approved_by = (select auth.uid()), approved_at = now()
    where borrowing_id = p_borrowing_id;
  end if;

  update public.equipment e
  set availability_status = case
    when coalesce((
      select sum(bi.quantity)
      from public.borrowing_items bi
      join public.borrowings b using (borrowing_id)
      where bi.equipment_id = e.equipment_id
        and b.transaction_status in ('approved', 'borrowed')
    ), 0) >= e.quantity then 'borrowed'
    else 'available'
  end
  where e.availability_status in ('available', 'borrowed')
    and e.equipment_id = v_request.equipment_id;
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
  if not public.is_equipment_staff_user() then
    raise exception 'Only administrators and property custodians can review reservations.';
  end if;
  if p_action is null or p_action not in ('approve', 'reject') then raise exception 'Choose approve or reject.'; end if;

  select * into v_row
  from public.reservations
  where reservation_id = p_reservation_id
  for update;
  if not found or v_row.status <> 'pending' then
    raise exception 'This reservation is no longer pending.';
  end if;

  perform 1 from public.equipment where equipment_id = v_row.equipment_id for update;
  if p_action = 'approve' and not public.equipment_period_has_capacity(
    v_row.equipment_id,
    v_row.start_date,
    v_row.end_date,
    v_row.quantity,
    null,
    v_row.reservation_id
  ) then
    raise exception 'The reserved amount is no longer available for the selected dates.';
  end if;

  update public.reservations
  set status = case when p_action = 'approve' then 'approved' else 'rejected' end,
      reviewed_by = (select auth.uid()),
      reviewed_at = now()
  where reservation_id = p_reservation_id;
end;
$$;

create or replace function public.equipment_available_quantities()
returns table (equipment_id bigint, available_quantity integer)
language sql
stable
security definer
set search_path = ''
as $$
  select e.equipment_id,
         greatest(0, e.quantity - coalesce(occupied.amount, 0))::integer
  from public.equipment e
  left join lateral (
    select sum(active.amount)::integer as amount
    from (
      select bi.quantity as amount
      from public.borrowing_items bi
      join public.borrowings b using (borrowing_id)
      where bi.equipment_id = e.equipment_id
        and b.transaction_status in ('approved', 'borrowed')
      union all
      select r.quantity as amount
      from public.reservations r
      where r.equipment_id = e.equipment_id
        and r.status in ('pending', 'approved')
        and r.start_date <= current_date
        and r.end_date >= current_date
    ) active
  ) occupied on true
  where e.deleted_at is null
    and (select auth.uid()) is not null;
$$;

revoke all on function public.equipment_period_has_capacity(bigint, date, date, integer, bigint, bigint) from public, anon, authenticated;
revoke all on function public.request_equipment_borrowing(bigint, text, text, timestamptz) from public, anon;
revoke all on function public.request_equipment_borrowing(bigint, text, text, timestamptz, integer) from public, anon;
revoke all on function public.request_equipment_reservation(bigint, text, text, date, date) from public, anon;
revoke all on function public.request_equipment_reservation(bigint, text, text, date, date, integer) from public, anon;
revoke all on function public.request_equipment_reservation(bigint, text, text, date, date, integer, time, time) from public, anon;
grant execute on function public.request_equipment_borrowing(bigint, text, text, timestamptz) to authenticated;
grant execute on function public.request_equipment_borrowing(bigint, text, text, timestamptz, integer) to authenticated;
grant execute on function public.request_equipment_reservation(bigint, text, text, date, date) to authenticated;
grant execute on function public.request_equipment_reservation(bigint, text, text, date, date, integer) to authenticated;
grant execute on function public.request_equipment_reservation(bigint, text, text, date, date, integer, time, time) to authenticated;
grant execute on function public.review_borrowing_request(bigint, text) to authenticated;
grant execute on function public.review_equipment_reservation(bigint, text) to authenticated;

notify pgrst, 'reload schema';
