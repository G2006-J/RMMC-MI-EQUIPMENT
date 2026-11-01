create or replace function public.equipment_period_has_capacity(
  p_equipment_id bigint,
  p_start_date date,
  p_end_date date
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_quantity integer;
  v_status text;
begin
  select e.quantity, e.availability_status
    into v_quantity, v_status
  from public.equipment e
  where e.equipment_id = p_equipment_id
    and e.deleted_at is null;

  if not found or v_quantity <= 0 or v_status in ('maintenance', 'retired') then
    return false;
  end if;

  return not exists (
    with active_periods as (
      select b.request_date::date as start_date, b.expected_return_date::date as end_date
      from public.borrowings b
      join public.borrowing_items bi using (borrowing_id)
      where bi.equipment_id = p_equipment_id
        and b.transaction_status in ('pending', 'approved', 'borrowed')
      union all
      select r.start_date, r.end_date
      from public.reservations r
      where r.equipment_id = p_equipment_id
        and r.status in ('pending', 'approved')
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
      select count(*)
      from active_periods active
      where active.start_date <= candidate.occupied_on
        and active.end_date >= candidate.occupied_on
    ) >= v_quantity
  );
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
  v_start_date date := current_date;
  v_end_date date := p_expected_return_date::date;
begin
  if v_user is null then raise exception 'Sign in before requesting equipment.'; end if;
  if not exists (
    select 1 from public.profiles p where p.id = v_user and p.account_status = 'active'
  ) then raise exception 'Your account is inactive.'; end if;

  select b.borrower_id into v_borrower
  from public.borrowers b
  where lower(b.email) = lower(v_email) and b.status = 'active'
  order by b.borrower_id
  limit 1;
  if v_borrower is null then
    raise exception 'No active borrower record matches your signed-in email. Contact the equipment administrator.';
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
    and e.quantity > 0
    and e.availability_status not in ('maintenance', 'retired')
  for update;
  if not found then raise exception 'This equipment is not currently available.'; end if;
  if not public.equipment_period_has_capacity(p_equipment_id, v_start_date, v_end_date) then
    raise exception 'There are no units available for the requested period.';
  end if;

  insert into public.borrowings (
    transaction_code, borrower_id, processed_by, purpose, destination, expected_return_date
  )
  values (
    'BR-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
    v_borrower, v_user, trim(p_purpose), trim(p_destination), p_expected_return_date
  )
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
  if not public.is_equipment_staff_user() then
    raise exception 'Only equipment staff can review borrowing requests.';
  end if;
  if p_action not in ('approve', 'reject') then raise exception 'Choose approve or reject.'; end if;

  perform 1
  from public.equipment e
  join public.borrowing_items bi on bi.equipment_id = e.equipment_id
  where bi.borrowing_id = p_borrowing_id
  for update of e;

  select b.transaction_status into v_status
  from public.borrowings b
  where b.borrowing_id = p_borrowing_id
  for update;
  if not found or v_status <> 'pending' then raise exception 'This request is no longer pending.'; end if;

  if p_action = 'approve' and exists (
    select 1
    from public.borrowing_items bi
    join public.equipment e using (equipment_id)
    where bi.borrowing_id = p_borrowing_id
      and (
        e.deleted_at is not null
        or e.availability_status in ('maintenance', 'retired')
        or e.quantity <= 0
      )
  ) then
    raise exception 'One or more requested items are no longer available.';
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
    when (
      select count(*)
      from public.borrowing_items bi
      join public.borrowings b using (borrowing_id)
      where bi.equipment_id = e.equipment_id
        and b.transaction_status in ('pending', 'approved', 'borrowed')
        and b.request_date::date <= current_date
        and b.expected_return_date::date >= current_date
    ) >= e.quantity then 'borrowed'
    else 'available'
  end
  where e.availability_status in ('available', 'borrowed')
    and exists (
      select 1 from public.borrowing_items bi
      where bi.borrowing_id = p_borrowing_id and bi.equipment_id = e.equipment_id
    );
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
    select 1
    from public.borrowings b
    where b.borrowing_id = p_borrowing_id
      and b.borrower_id = public.current_borrower_id()
      and b.transaction_status in ('approved', 'borrowed')
  ) then
    raise exception 'This borrowing is not eligible for a return request.';
  end if;

  insert into public.return_requests (borrowing_id, requested_by)
  values (p_borrowing_id, (select auth.uid()))
  on conflict (borrowing_id) where status = 'pending' do nothing;
end;
$$;

create or replace function public.complete_equipment_return(p_borrowing_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_equipment_staff_user() then
    raise exception 'Only equipment staff can confirm returns.';
  end if;

  perform 1
  from public.equipment e
  join public.borrowing_items bi on bi.equipment_id = e.equipment_id
  where bi.borrowing_id = p_borrowing_id
  for update of e;

  if not exists (
    select 1
    from public.borrowings b
    where b.borrowing_id = p_borrowing_id
      and b.transaction_status in ('approved', 'borrowed')
  ) then
    raise exception 'This borrowing is no longer active.';
  end if;

  update public.borrowing_items
  set item_status = 'returned', returned_at = now()
  where borrowing_id = p_borrowing_id and item_status in ('issued', 'pending');

  update public.borrowings
  set transaction_status = 'returned', updated_at = now()
  where borrowing_id = p_borrowing_id;

  update public.return_requests
  set status = 'completed', completed_at = now()
  where borrowing_id = p_borrowing_id and status = 'pending';

  update public.equipment e
  set availability_status = case
    when (
      select count(*)
      from public.borrowing_items bi
      join public.borrowings b using (borrowing_id)
      where bi.equipment_id = e.equipment_id
        and b.transaction_status in ('pending', 'approved', 'borrowed')
        and b.request_date::date <= current_date
        and b.expected_return_date::date >= current_date
    ) >= e.quantity then 'borrowed'
    else 'available'
  end
  where e.availability_status in ('available', 'borrowed')
    and exists (
      select 1 from public.borrowing_items bi
      where bi.borrowing_id = p_borrowing_id and bi.equipment_id = e.equipment_id
    );
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
  v_user uuid := (select auth.uid());
  v_borrower bigint := public.current_borrower_id();
  v_id bigint;
begin
  if v_user is null then raise exception 'Sign in before reserving equipment.'; end if;
  if not exists (
    select 1 from public.profiles p where p.id = v_user and p.account_status = 'active'
  ) then raise exception 'Your account is inactive.'; end if;
  if v_borrower is null then
    raise exception 'No active borrower record matches your signed-in email. Contact the equipment administrator.';
  end if;
  if p_start_date is null or p_end_date is null or p_start_date < current_date or p_end_date < p_start_date then
    raise exception 'Choose a valid future reservation date range.';
  end if;
  if nullif(trim(p_purpose), '') is null or nullif(trim(p_destination), '') is null then
    raise exception 'Purpose and destination are required.';
  end if;

  perform 1
  from public.equipment e
  where e.equipment_id = p_equipment_id
    and e.deleted_at is null
    and e.quantity > 0
    and e.availability_status not in ('maintenance', 'retired')
  for update;
  if not found then raise exception 'This equipment is not available to reserve.'; end if;
  if not public.equipment_period_has_capacity(p_equipment_id, p_start_date, p_end_date) then
    raise exception 'There are no units available for the selected reservation dates.';
  end if;

  insert into public.reservations (
    requested_by, borrower_id, equipment_id, purpose, destination, start_date, end_date
  )
  values (
    v_user, v_borrower, p_equipment_id, trim(p_purpose), trim(p_destination), p_start_date, p_end_date
  )
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
  if not public.is_equipment_staff_user() then
    raise exception 'Only equipment staff can review reservations.';
  end if;
  if p_action not in ('approve', 'reject') then raise exception 'Choose approve or reject.'; end if;

  select * into v_row
  from public.reservations
  where reservation_id = p_reservation_id
  for update;
  if not found or v_row.status <> 'pending' then
    raise exception 'This reservation is no longer pending.';
  end if;

  update public.reservations
  set status = case when p_action = 'approve' then 'approved' else 'rejected' end,
      reviewed_by = (select auth.uid()),
      reviewed_at = now()
  where reservation_id = p_reservation_id;
end;
$$;

revoke all on function public.equipment_period_has_capacity(bigint, date, date) from public, anon, authenticated;
revoke all on function public.request_equipment_borrowing(bigint, text, text, timestamptz) from public, anon;
revoke all on function public.review_borrowing_request(bigint, text) from public, anon;
revoke all on function public.request_equipment_return(bigint) from public, anon;
revoke all on function public.complete_equipment_return(bigint) from public, anon;
revoke all on function public.request_equipment_reservation(bigint, text, text, date, date) from public, anon;
revoke all on function public.review_equipment_reservation(bigint, text) from public, anon;

grant execute on function public.request_equipment_borrowing(bigint, text, text, timestamptz) to authenticated;
grant execute on function public.review_borrowing_request(bigint, text) to authenticated;
grant execute on function public.request_equipment_return(bigint) to authenticated;
grant execute on function public.complete_equipment_return(bigint) to authenticated;
grant execute on function public.request_equipment_reservation(bigint, text, text, date, date) to authenticated;
grant execute on function public.review_equipment_reservation(bigint, text) to authenticated;
