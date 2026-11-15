begin;

create or replace function public.equipment_available_quantities()
returns table (equipment_id bigint, available_quantity integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_verified_active_user()
    or not exists (select 1 from public.profiles p where p.id = (select auth.uid())
      and p.role in ('staff', 'admin', 'property_custodian')) then
    raise exception 'Sign in with an active account to view availability.';
  end if;
  return query
  select e.equipment_id,
    case when e.tracking_mode = 'quantity' and e.availability_status in ('maintenance', 'retired') then 0
      when e.tracking_mode = 'unit' then greatest(0,
        (select count(*)::integer from public.equipment_units u
          where u.equipment_id = e.equipment_id and u.status = 'available')
        - coalesce(occupied.amount, 0))
      else greatest(0, e.quantity - e.out_of_service_quantity - coalesce(occupied.amount, 0))
    end::integer
  from public.equipment e
  left join lateral (
    select sum(x.amount)::integer amount from (
      select coalesce(sum(bi.quantity), 0)::integer amount from public.borrowing_items bi
      join public.borrowings b using (borrowing_id)
      where bi.equipment_id = e.equipment_id
        and b.transaction_status in ('approved', 'released')
        and (e.tracking_mode <> 'unit' or b.transaction_status = 'approved')
        and b.request_date::date <= current_date
        and (b.transaction_status = 'released' or b.expected_return_date::date >= current_date)
      union all
      select coalesce(sum(r.quantity), 0)::integer from public.reservations r
      where r.equipment_id = e.equipment_id and r.status = 'approved'
        and r.start_date <= current_date and r.end_date >= current_date
    ) x
  ) occupied on true
  where e.deleted_at is null;
end;
$$;
revoke all on function public.equipment_available_quantities() from public, anon;
grant execute on function public.equipment_available_quantities() to authenticated;

commit;
