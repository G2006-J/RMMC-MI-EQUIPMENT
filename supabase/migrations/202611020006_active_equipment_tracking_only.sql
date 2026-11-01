drop function if exists public.list_equipment_tracking_records();

create or replace function public.list_equipment_tracking_records()
returns table (
  record_id text,
  record_type text,
  record_status text,
  borrowing_id bigint,
  reservation_id bigint,
  equipment_id bigint,
  equipment_name text,
  asset_code text,
  category_name text,
  equipment_image_url text,
  storage_location text,
  amount integer,
  total_quantity integer,
  borrower_name text,
  department text,
  destination text,
  start_date date,
  end_date date,
  pickup_at timestamptz,
  return_at timestamptz,
  profile_photo_path text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can view equipment tracking.';
  end if;

  return query
  select
    ('borrow-' || bi.borrowing_item_id::text)::text,
    'borrow'::text,
    case when b.expected_return_date < now() then 'overdue' else 'borrowed' end::text,
    b.borrowing_id,
    null::bigint,
    e.equipment_id,
    e.equipment_name::text,
    e.asset_code::text,
    c.category_name::text,
    e.image_url::text,
    e.storage_location::text,
    bi.quantity::integer,
    e.quantity::integer,
    concat_ws(' ', br.first_name, br.middle_name, br.last_name)::text,
    coalesce(br.department, '')::text,
    b.destination::text,
    b.request_date::date,
    b.expected_return_date::date,
    bi.issued_at,
    b.expected_return_date,
    br.profile_photo_path
  from public.borrowings b
  join public.borrowers br on br.borrower_id = b.borrower_id
  join public.borrowing_items bi on bi.borrowing_id = b.borrowing_id
  join public.equipment e on e.equipment_id = bi.equipment_id
  join public.categories c on c.category_id = e.category_id
  where b.transaction_status in ('approved', 'borrowed')
    and bi.item_status = 'issued'

  union all

  select
    ('reservation-' || r.reservation_id::text)::text,
    'reservation'::text,
    'reserved'::text,
    null::bigint,
    r.reservation_id,
    e.equipment_id,
    e.equipment_name::text,
    e.asset_code::text,
    c.category_name::text,
    e.image_url::text,
    e.storage_location::text,
    r.quantity::integer,
    e.quantity::integer,
    concat_ws(' ', br.first_name, br.middle_name, br.last_name)::text,
    coalesce(br.department, '')::text,
    r.destination::text,
    r.start_date,
    r.end_date,
    (r.start_date + r.start_time) at time zone 'Asia/Manila',
    (r.end_date + r.end_time) at time zone 'Asia/Manila',
    br.profile_photo_path
  from public.reservations r
  join public.borrowers br on br.borrower_id = r.borrower_id
  join public.equipment e on e.equipment_id = r.equipment_id
  join public.categories c on c.category_id = e.category_id
  where r.status in ('pending', 'approved')
    and (r.end_date + r.end_time) at time zone 'Asia/Manila' >= now()
  order by 3, 17, 7;
end;
$$;

revoke all on function public.list_equipment_tracking_records() from public, anon;
grant execute on function public.list_equipment_tracking_records() to authenticated;

notify pgrst, 'reload schema';
