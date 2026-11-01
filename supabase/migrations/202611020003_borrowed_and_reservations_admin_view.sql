drop policy if exists "verified users read profile photos" on storage.objects;
create policy "verified users read profile photos"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'profile-photos'
    and public.is_verified_active_user()
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or public.is_equipment_manager_user()
    )
  );

drop function if exists public.list_currently_borrowed_equipment();

create function public.list_currently_borrowed_equipment()
returns table (
  borrowing_id bigint,
  borrowing_item_id bigint,
  reservation_id bigint,
  record_type text,
  record_status text,
  equipment_id bigint,
  equipment_name text,
  asset_code text,
  amount integer,
  borrower_name text,
  department text,
  destination text,
  start_date date,
  end_date date,
  profile_photo_path text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can view all borrowed and reserved equipment.';
  end if;

  return query
  select b.borrowing_id,
         bi.borrowing_item_id,
         null::bigint,
         'borrow'::text,
         b.transaction_status::text,
         e.equipment_id,
         e.equipment_name::text,
         e.asset_code::text,
         1::integer,
         concat_ws(' ', br.first_name, br.middle_name, br.last_name)::text,
         coalesce(br.department, '')::text,
         b.destination::text,
         b.request_date::date,
         b.expected_return_date::date,
         br.profile_photo_path
  from public.borrowings b
  join public.borrowers br on br.borrower_id = b.borrower_id
  join public.borrowing_items bi on bi.borrowing_id = b.borrowing_id
  join public.equipment e on e.equipment_id = bi.equipment_id
  where b.transaction_status = 'borrowed'
    and bi.item_status = 'issued'
  union all
  select null::bigint,
         null::bigint,
         r.reservation_id,
         'reservation'::text,
         r.status::text,
         e.equipment_id,
         e.equipment_name::text,
         e.asset_code::text,
         1::integer,
         concat_ws(' ', br.first_name, br.middle_name, br.last_name)::text,
         coalesce(br.department, '')::text,
         r.destination::text,
         r.start_date,
         r.end_date,
         br.profile_photo_path
  from public.reservations r
  join public.borrowers br on br.borrower_id = r.borrower_id
  join public.equipment e on e.equipment_id = r.equipment_id
  where r.status in ('pending', 'approved')
    and r.end_date >= current_date
  order by 14, 7;
end;
$$;

revoke all on function public.list_currently_borrowed_equipment() from public, anon;
grant execute on function public.list_currently_borrowed_equipment() to authenticated;

notify pgrst, 'reload schema';
