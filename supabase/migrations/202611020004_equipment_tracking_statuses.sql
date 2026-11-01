drop function if exists public.list_equipment_tracking_records();

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
    where conname = 'borrowing_items_quantity_positive'
      and conrelid = 'public.borrowing_items'::regclass
  ) then
    alter table public.borrowing_items
      add constraint borrowing_items_quantity_positive check (quantity > 0);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'reservations_quantity_positive'
      and conrelid = 'public.reservations'::regclass
  ) then
    alter table public.reservations
      add constraint reservations_quantity_positive check (quantity > 0);
  end if;
end;
$$;

create function public.list_equipment_tracking_records()
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
  with records as (
    select
      ('inventory-' || e.equipment_id::text)::text as record_id,
      'inventory'::text as record_type,
      case
        when e.availability_status in ('maintenance', 'retired') then e.availability_status
        when availability.available_quantity > 0 then 'available'
        else 'unavailable'
      end::text as record_status,
      null::bigint as borrowing_id,
      null::bigint as reservation_id,
      e.equipment_id,
      e.equipment_name::text,
      e.asset_code::text,
      c.category_name::text,
      e.image_url::text,
      e.storage_location::text,
      availability.available_quantity as amount,
      e.quantity::integer as total_quantity,
      null::text as borrower_name,
      null::text as department,
      null::text as destination,
      null::date as start_date,
      null::date as end_date,
      null::timestamptz as pickup_at,
      null::timestamptz as return_at,
      null::text as profile_photo_path
    from public.equipment e
    join public.categories c on c.category_id = e.category_id
    cross join lateral (
      select greatest(0, e.quantity - coalesce((
        select sum(occupied_items.quantity)::integer
        from (
          select occupied_item.quantity
          from public.borrowing_items occupied_item
          join public.borrowings occupied on occupied.borrowing_id = occupied_item.borrowing_id
          where occupied_item.equipment_id = e.equipment_id
            and occupied.transaction_status in ('approved', 'borrowed')
          union all
          select active_reservation.quantity
          from public.reservations active_reservation
          where active_reservation.equipment_id = e.equipment_id
            and active_reservation.status in ('pending', 'approved')
            and active_reservation.start_date <= current_date
            and active_reservation.end_date >= current_date
        ) occupied_items
      ), 0))::integer as available_quantity
    ) availability
    where e.deleted_at is null

    union all

    select
      ('borrow-' || bi.borrowing_item_id::text)::text,
      'borrow'::text,
      case when b.expected_return_date::date < current_date then 'overdue' else 'borrowed' end::text,
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
      and r.end_date >= current_date

    union all

    select
      ('returned-' || bi.borrowing_item_id::text)::text,
      'returned'::text,
      'returned'::text,
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
      coalesce(bi.returned_at, b.updated_at)::date,
      bi.issued_at,
      bi.returned_at,
      br.profile_photo_path
    from public.borrowings b
    join public.borrowers br on br.borrower_id = b.borrower_id
    join public.borrowing_items bi on bi.borrowing_id = b.borrowing_id
    join public.equipment e on e.equipment_id = bi.equipment_id
    join public.categories c on c.category_id = e.category_id
    where b.transaction_status = 'returned'
      and bi.item_status = 'returned'
  )
  select records.record_id,
         records.record_type,
         records.record_status,
         records.borrowing_id,
         records.reservation_id,
         records.equipment_id,
         records.equipment_name,
         records.asset_code,
         records.category_name,
         records.equipment_image_url,
         records.storage_location,
         records.amount,
         records.total_quantity,
         records.borrower_name,
         records.department,
         records.destination,
         records.start_date,
         records.end_date,
         records.pickup_at,
         records.return_at,
         records.profile_photo_path
  from records
  order by case records.record_status
    when 'overdue' then 1
    when 'borrowed' then 2
    when 'reserved' then 3
    when 'available' then 4
    when 'unavailable' then 5
    when 'maintenance' then 6
    when 'retired' then 7
    when 'returned' then 8
    else 9
  end, records.end_date nulls last, records.equipment_name;
end;
$$;

revoke all on function public.list_equipment_tracking_records() from public, anon;
grant execute on function public.list_equipment_tracking_records() to authenticated;

notify pgrst, 'reload schema';
