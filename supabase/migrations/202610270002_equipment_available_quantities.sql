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
        where b.transaction_status in ('pending', 'approved', 'borrowed')
          and b.request_date::date <= current_date
          and (
            b.transaction_status in ('approved', 'borrowed')
            or b.expected_return_date::date >= current_date
          )
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
          when b.transaction_status in ('approved', 'borrowed')
            and b.expected_return_date::date < current_date
            then 'infinity'::date
          else b.expected_return_date::date
        end as end_date
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

revoke all on function public.equipment_available_quantities() from public, anon, authenticated;
grant execute on function public.equipment_available_quantities() to authenticated;

notify pgrst, 'reload schema';
