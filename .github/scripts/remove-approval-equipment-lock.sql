create or replace function public.review_borrowing_request(
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
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can review borrowing requests.';
  end if;
  if p_action is null or p_action not in ('approve', 'reject') then
    raise exception 'Choose approve or reject.';
  end if;
  if p_action = 'reject' and nullif(trim(p_decline_reason), '') is null then
    raise exception 'A reason is required to decline a borrowing request.';
  end if;

  select b.* into v_request
  from public.borrowings b
  where b.borrowing_id = p_borrowing_id
  for update;
  if not found or v_request.transaction_status <> 'requested' then
    raise exception 'This request is no longer awaiting review.';
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
    set item_status = 'approved'
    where borrowing_id = p_borrowing_id and item_status = 'requested';
  else
    update public.borrowings
    set transaction_status = 'rejected',
        approved_by = v_actor,
        approved_at = now(),
        decline_reason = trim(p_decline_reason),
        updated_at = now()
    where borrowing_id = p_borrowing_id;
    update public.borrowing_items
    set item_status = 'rejected'
    where borrowing_id = p_borrowing_id and item_status = 'requested';
  end if;

  update public.equipment e
  set availability_status = case
    when coalesce((
      select sum(bi.quantity)
      from public.borrowing_items bi
      join public.borrowings b using (borrowing_id)
      where bi.equipment_id = e.equipment_id
        and b.transaction_status in ('approved', 'released')
    ), 0) >= e.quantity then 'borrowed'
    else 'available'
  end
  where e.availability_status in ('available', 'borrowed')
    and e.equipment_id in (
      select bi.equipment_id from public.borrowing_items bi
      where bi.borrowing_id = p_borrowing_id
    );
end;
$$;
