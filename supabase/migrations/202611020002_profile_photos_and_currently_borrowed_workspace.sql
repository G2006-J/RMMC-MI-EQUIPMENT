alter table public.profiles
  add column if not exists profile_photo_path text;

alter table public.borrowers
  add column if not exists profile_photo_path text;

update public.borrowers b
set department = coalesce(nullif(b.department, ''), p.department),
    course = coalesce(nullif(b.course, ''), p.course),
    profile_photo_path = coalesce(b.profile_photo_path, p.profile_photo_path)
from public.profiles p
where lower(b.email) = lower(p.email)
  and (
    b.department is null or b.department = ''
    or b.course is null or b.course = ''
    or b.profile_photo_path is null
  );

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'profile-photos',
  'profile-photos',
  false,
  5242880,
  array['image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

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

drop policy if exists "users upload own profile photos" on storage.objects;
create policy "users upload own profile photos"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'profile-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and public.is_verified_active_user()
  );

drop policy if exists "users update own profile photos" on storage.objects;
create policy "users update own profile photos"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'profile-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and public.is_verified_active_user()
  )
  with check (
    bucket_id = 'profile-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and public.is_verified_active_user()
  );

drop policy if exists "users delete own profile photos" on storage.objects;
create policy "users delete own profile photos"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'profile-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and public.is_verified_active_user()
  );

create or replace function public.update_my_profile_photo(p_profile_photo_path text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_borrower_id bigint;
begin
  if not public.is_verified_active_user() then
    raise exception 'Sign in with a verified, active account to update your profile photo.';
  end if;
  if p_profile_photo_path is not null and (
    split_part(p_profile_photo_path, '/', 1) <> (select auth.uid())::text
    or split_part(p_profile_photo_path, '/', 2) = ''
    or split_part(p_profile_photo_path, '/', 3) <> ''
    or right(p_profile_photo_path, 5) <> '.webp'
    or length(p_profile_photo_path) > 120
  ) then
    raise exception 'The profile photo path is invalid.';
  end if;

  update public.profiles
  set profile_photo_path = p_profile_photo_path,
      updated_at = now()
  where id = (select auth.uid());
  if not found then
    raise exception 'Your profile could not be found.';
  end if;

  v_borrower_id := public.current_borrower_id();
  if v_borrower_id is not null then
    update public.borrowers
    set profile_photo_path = p_profile_photo_path
    where borrower_id = v_borrower_id;
  end if;
end;
$$;

revoke all on function public.update_my_profile_photo(text) from public, anon;
grant execute on function public.update_my_profile_photo(text) to authenticated;

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
