alter table public.borrowings
  add column if not exists decline_reason text;
alter table public.borrowings
  drop constraint if exists borrowings_decline_reason_required;
update public.borrowings
set decline_reason = 'Declined before a reason was required.'
where transaction_status = 'rejected'
  and nullif(trim(decline_reason), '') is null;
alter table public.borrowings
  add constraint borrowings_decline_reason_required
  check (transaction_status <> 'rejected' or nullif(trim(decline_reason), '') is not null);

alter table public.reservations
  add column if not exists decline_reason text,
  add column if not exists picked_up_at timestamptz;
alter table public.reservations
  drop constraint if exists reservations_status_check,
  drop constraint if exists reservations_decline_reason_required;
update public.reservations
set decline_reason = 'Declined before a reason was required.'
where status = 'rejected'
  and nullif(trim(decline_reason), '') is null;
alter table public.reservations
  add constraint reservations_status_check
    check (status in ('pending', 'approved', 'rejected', 'cancelled', 'fulfilled', 'expired')),
  add constraint reservations_decline_reason_required
    check (status <> 'rejected' or nullif(trim(decline_reason), '') is not null);

create table public.reservation_settings (
  singleton boolean primary key default true check (singleton),
  pickup_grace_period_minutes integer not null default 30
    check (pickup_grace_period_minutes between 1 and 1440)
);

insert into public.reservation_settings (singleton)
values (true)
on conflict (singleton) do nothing;

alter table public.reservation_settings enable row level security;
revoke all on public.reservation_settings from anon, authenticated;
grant select on public.reservation_settings to authenticated;
grant update (pickup_grace_period_minutes) on public.reservation_settings to authenticated;
create policy "equipment managers read reservation settings"
  on public.reservation_settings for select to authenticated
  using (public.is_equipment_manager_user());
create policy "equipment managers update reservation settings"
  on public.reservation_settings for update to authenticated
  using (singleton and public.is_equipment_manager_user())
  with check (singleton and public.is_equipment_manager_user());

create or replace function public.equipment_period_has_approval_capacity(
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
  if not found or v_quantity < p_requested_quantity
    or v_status in ('maintenance', 'retired') then
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
        and b.transaction_status in ('approved', 'borrowed')
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
revoke all on function public.equipment_period_has_approval_capacity(bigint, date, date, integer, bigint, bigint)
  from public, anon, authenticated;

drop function if exists public.review_borrowing_request(bigint, text);
create function public.review_borrowing_request(
  p_borrowing_id bigint,
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
  v_request public.borrowings%rowtype;
  v_item record;
begin
  if v_actor is null or not public.is_equipment_staff_user() then
    raise exception 'Only administrators and property custodians can review borrowing requests.';
  end if;
  if p_action is null or p_action not in ('approve', 'reject') then
    raise exception 'Choose approve or reject.';
  end if;
  if p_action = 'reject' and nullif(trim(p_decline_reason), '') is null then
    raise exception 'A reason is required to decline a borrowing request.';
  end if;

  perform e.equipment_id
  from public.equipment e
  join public.borrowing_items bi on bi.equipment_id = e.equipment_id
  where bi.borrowing_id = p_borrowing_id
  order by e.equipment_id
  for update of e;

  select b.* into v_request
  from public.borrowings b
  where b.borrowing_id = p_borrowing_id
  for update;
  if not found or v_request.transaction_status <> 'pending' then
    raise exception 'This request is no longer pending.';
  end if;

  if p_action = 'approve' then
    for v_item in
      select bi.equipment_id, bi.quantity, e.deleted_at, e.availability_status
      from public.borrowing_items bi
      join public.equipment e on e.equipment_id = bi.equipment_id
      where bi.borrowing_id = p_borrowing_id
      order by e.equipment_id
    loop
      if v_item.deleted_at is not null
        or v_item.availability_status in ('maintenance', 'retired')
        or not public.equipment_period_has_approval_capacity(
          v_item.equipment_id,
          v_request.request_date::date,
          v_request.expected_return_date::date,
          v_item.quantity,
          p_borrowing_id,
          null
        ) then
        raise exception 'The requested amount is no longer available.';
      end if;
    end loop;

    update public.borrowings
    set transaction_status = 'approved',
        approved_by = v_actor,
        approved_at = now(),
        decline_reason = null,
        updated_at = now()
    where borrowing_id = p_borrowing_id;
    update public.borrowing_items
    set item_status = 'issued', issued_at = now()
    where borrowing_id = p_borrowing_id;
  else
    update public.borrowings
    set transaction_status = 'rejected',
        approved_by = v_actor,
        approved_at = now(),
        decline_reason = trim(p_decline_reason),
        updated_at = now()
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
    and e.equipment_id in (
      select bi.equipment_id
      from public.borrowing_items bi
      where bi.borrowing_id = p_borrowing_id
    );
end;
$$;
revoke all on function public.review_borrowing_request(bigint, text, text) from public, anon;
grant execute on function public.review_borrowing_request(bigint, text, text) to authenticated;

drop function if exists public.review_equipment_reservation(bigint, text);
create function public.review_equipment_reservation(
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
  v_row public.reservations%rowtype;
begin
  if v_actor is null or not public.is_equipment_staff_user() then
    raise exception 'Only administrators and property custodians can review reservations.';
  end if;
  if p_action is null or p_action not in ('approve', 'reject') then
    raise exception 'Choose approve or reject.';
  end if;
  if p_action = 'reject' and nullif(trim(p_decline_reason), '') is null then
    raise exception 'A reason is required to decline a reservation.';
  end if;

  select * into v_row
  from public.reservations
  where reservation_id = p_reservation_id
  for update;
  if not found or v_row.status <> 'pending' then
    raise exception 'This reservation is no longer pending.';
  end if;

  perform 1
  from public.equipment
  where equipment_id = v_row.equipment_id
  for update;
  if not found then
    raise exception 'The requested equipment no longer exists.';
  end if;

  if p_action = 'approve' and not public.equipment_period_has_approval_capacity(
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
      decline_reason = case when p_action = 'reject' then trim(p_decline_reason) else null end,
      reviewed_by = v_actor,
      reviewed_at = now()
  where reservation_id = p_reservation_id;
end;
$$;
revoke all on function public.review_equipment_reservation(bigint, text, text) from public, anon;
grant execute on function public.review_equipment_reservation(bigint, text, text) to authenticated;

create or replace function public.cancel_my_pending_borrowing(p_borrowing_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_borrower bigint;
begin
  if v_user is null or not public.is_verified_active_user() then
    raise exception 'Sign in with a verified, active account to cancel a request.';
  end if;
  if not exists (
    select 1 from public.profiles p where p.id = v_user and p.role = 'staff'
  ) then
    raise exception 'Only borrowers can cancel borrowing requests.';
  end if;
  v_borrower := public.current_borrower_id();
  if v_borrower is null then
    raise exception 'Your borrower account is not active.';
  end if;

  update public.borrowings
  set transaction_status = 'cancelled', updated_at = now()
  where borrowing_id = p_borrowing_id
    and borrower_id = v_borrower
    and transaction_status = 'pending';
  if not found then
    raise exception 'Only your pending borrowing requests can be cancelled.';
  end if;
end;
$$;
revoke all on function public.cancel_my_pending_borrowing(bigint) from public, anon;
grant execute on function public.cancel_my_pending_borrowing(bigint) to authenticated;

create or replace function public.cancel_my_pending_reservation(p_reservation_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_borrower bigint;
begin
  if v_user is null or not public.is_verified_active_user() then
    raise exception 'Sign in with a verified, active account to cancel a reservation.';
  end if;
  if not exists (
    select 1 from public.profiles p where p.id = v_user and p.role = 'staff'
  ) then
    raise exception 'Only borrowers can cancel reservations.';
  end if;
  v_borrower := public.current_borrower_id();
  if v_borrower is null then
    raise exception 'Your borrower account is not active.';
  end if;

  update public.reservations
  set status = 'cancelled'
  where reservation_id = p_reservation_id
    and requested_by = v_user
    and borrower_id = v_borrower
    and status = 'pending';
  if not found then
    raise exception 'Only your pending reservations can be cancelled.';
  end if;
end;
$$;
revoke all on function public.cancel_my_pending_reservation(bigint) from public, anon;
grant execute on function public.cancel_my_pending_reservation(bigint) to authenticated;

create or replace function public.mark_reservation_picked_up(p_reservation_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
begin
  if v_actor is null or not public.is_equipment_staff_user() then
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

create or replace function public.expire_unpicked_reservations()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_expired integer;
begin
  update public.reservations r
  set status = 'expired'
  from public.reservation_settings s
  where s.singleton
    and r.status = 'approved'
    and r.picked_up_at is null
    and ((r.start_date + r.start_time) at time zone current_setting('TimeZone'))
      + make_interval(mins => s.pickup_grace_period_minutes) < now();
  get diagnostics v_expired = row_count;
  return v_expired;
end;
$$;
revoke all on function public.expire_unpicked_reservations() from public, anon, authenticated;

create extension if not exists pg_cron;

do $$
declare
  v_job_id bigint;
begin
  select jobid into v_job_id
  from cron.job
  where jobname = 'expire-unpicked-reservations';
  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;
  perform cron.schedule(
    'expire-unpicked-reservations',
    '* * * * *',
    'select public.expire_unpicked_reservations();'
  );
end;
$$;

notify pgrst, 'reload schema';
