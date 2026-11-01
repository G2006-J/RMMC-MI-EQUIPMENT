create or replace function public.equipment_available_quantities()
returns table (equipment_id bigint, available_quantity integer)
language sql
stable
security definer
set search_path = ''
as $$
  select
    e.equipment_id,
    greatest(
      0,
      e.quantity - count(bi.borrowing_id) filter (
        where b.transaction_status in ('approved', 'borrowed')
      )::integer
    ) as available_quantity
  from public.equipment e
  left join public.borrowing_items bi on bi.equipment_id = e.equipment_id
  left join public.borrowings b on b.borrowing_id = bi.borrowing_id
  where e.deleted_at is null
    and (select auth.uid()) is not null
  group by e.equipment_id, e.quantity;
$$;

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
      select
        b.request_date::date as start_date,
        case
          when b.expected_return_date::date < current_date then 'infinity'::date
          else b.expected_return_date::date
        end as end_date
      from public.borrowings b
      join public.borrowing_items bi using (borrowing_id)
      where bi.equipment_id = p_equipment_id
        and b.transaction_status in ('approved', 'borrowed')
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
    join public.borrowings b using (borrowing_id)
    where bi.borrowing_id = p_borrowing_id
      and (
        e.deleted_at is not null
        or e.availability_status in ('maintenance', 'retired')
        or e.quantity <= 0
        or not public.equipment_period_has_capacity(
          e.equipment_id,
          b.request_date::date,
          b.expected_return_date::date
        )
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
        and b.transaction_status in ('approved', 'borrowed')
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
          and b.transaction_status in ('approved', 'borrowed')
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

notify pgrst, 'reload schema';