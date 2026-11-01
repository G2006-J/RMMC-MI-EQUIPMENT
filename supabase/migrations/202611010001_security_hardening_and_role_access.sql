create or replace function public.is_verified_active_user()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from auth.users u
    join public.profiles p on p.id = u.id
    where u.id = (select auth.uid())
      and u.email_confirmed_at is not null
      and p.account_status = 'active'
  );
$$;

create or replace function public.is_equipment_admin_user()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_verified_active_user()
    and exists (
      select 1
      from public.profiles p
      where p.id = (select auth.uid()) and p.role = 'admin'
    );
$$;

create or replace function public.is_equipment_staff_user()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_equipment_admin_user();
$$;

create or replace function public.is_equipment_manager_user()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and p.role in ('admin', 'property_custodian')
      and p.account_status = 'active'
  ) and public.is_verified_active_user();
$$;

revoke all on function public.is_verified_active_user() from public, anon;
grant execute on function public.is_verified_active_user() to authenticated;

revoke all on function public.is_equipment_manager_user() from public, anon;
grant execute on function public.is_equipment_manager_user() to authenticated;

update storage.buckets
set allowed_mime_types = array['image/webp'],
    file_size_limit = 5242880
where id = 'equipment-images';

drop policy if exists "read own profile and staff profiles" on public.profiles;
create policy "read own profile and administrators" on public.profiles for select to authenticated
using (
  public.is_verified_active_user()
  and (id = (select auth.uid()) or public.is_equipment_staff_user())
);

drop policy if exists "update own profile name" on public.profiles;
create policy "update own verified profile" on public.profiles for update to authenticated
using (id = (select auth.uid()) and public.is_verified_active_user())
with check (id = (select auth.uid()) and public.is_verified_active_user());

drop policy if exists "authenticated read active equipment" on public.equipment;
create policy "verified users read active equipment" on public.equipment for select to authenticated
using (public.is_verified_active_user() and deleted_at is null);

drop policy if exists "admins manage equipment" on public.equipment;
create policy "equipment managers manage equipment" on public.equipment for all to authenticated
using (public.is_equipment_manager_user())
with check (public.is_equipment_manager_user());

drop policy if exists "authenticated read categories" on public.categories;
create policy "verified users read categories" on public.categories for select to authenticated
using (public.is_verified_active_user());

drop policy if exists "read borrower records" on public.borrowers;
create policy "read verified borrower records" on public.borrowers for select to authenticated
using (
  public.is_verified_active_user()
  and (lower(email) = lower((select auth.jwt() ->> 'email')) or public.is_equipment_staff_user())
);

drop policy if exists "read relevant borrowings" on public.borrowings;
create policy "read verified relevant borrowings" on public.borrowings for select to authenticated
using (
  public.is_verified_active_user()
  and (borrower_id = public.current_borrower_id() or public.is_equipment_staff_user())
);

drop policy if exists "read relevant borrowing items" on public.borrowing_items;
create policy "read verified relevant borrowing items" on public.borrowing_items for select to authenticated
using (
  public.is_verified_active_user()
  and exists (
    select 1
    from public.borrowings b
    where b.borrowing_id = borrowing_items.borrowing_id
      and (b.borrower_id = public.current_borrower_id() or public.is_equipment_staff_user())
  )
);

drop policy if exists "read relevant reservations" on public.reservations;
create policy "read verified relevant reservations" on public.reservations for select to authenticated
using (
  public.is_verified_active_user()
  and (requested_by = (select auth.uid()) or public.is_equipment_staff_user())
);

drop policy if exists "read relevant return requests" on public.return_requests;
create policy "read verified relevant return requests" on public.return_requests for select to authenticated
using (
  public.is_verified_active_user()
  and (requested_by = (select auth.uid()) or public.is_equipment_staff_user())
);

drop policy if exists "admins read equipment audit" on public.equipment_audit_log;
create policy "equipment managers read equipment audit" on public.equipment_audit_log for select to authenticated
using (public.is_equipment_manager_user());

drop policy if exists "authenticated read feedback threads" on public.feedback_threads;
create policy "verified users read feedback threads" on public.feedback_threads for select to authenticated
using (public.is_verified_active_user());

drop policy if exists "authenticated create feedback threads" on public.feedback_threads;
create policy "verified users create feedback threads" on public.feedback_threads for insert to authenticated
with check (public.is_verified_active_user() and author_id = (select auth.uid()));

drop policy if exists "admins update feedback threads" on public.feedback_threads;
create policy "equipment managers update feedback threads" on public.feedback_threads for update to authenticated
using (public.is_equipment_manager_user())
with check (public.is_equipment_manager_user());

drop policy if exists "authenticated read feedback replies" on public.feedback_replies;
create policy "verified users read feedback replies" on public.feedback_replies for select to authenticated
using (public.is_verified_active_user());

drop policy if exists "authenticated create feedback replies" on public.feedback_replies;
create policy "verified users create feedback replies" on public.feedback_replies for insert to authenticated
with check (public.is_verified_active_user() and author_id = (select auth.uid()));

drop policy if exists "admins upload equipment images" on storage.objects;
drop policy if exists "admins update equipment images" on storage.objects;
drop policy if exists "admins delete equipment images" on storage.objects;

create policy "equipment managers upload images"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'equipment-images' and public.is_equipment_manager_user());
create policy "equipment managers update images"
  on storage.objects for update to authenticated
  using (bucket_id = 'equipment-images' and public.is_equipment_manager_user())
  with check (bucket_id = 'equipment-images' and public.is_equipment_manager_user());
create policy "equipment managers delete images"
  on storage.objects for delete to authenticated
  using (bucket_id = 'equipment-images' and public.is_equipment_manager_user());

create or replace function public.current_borrower_id()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select b.borrower_id
  from public.borrowers b
  where public.is_verified_active_user()
    and lower(b.email) = lower((select auth.jwt() ->> 'email'))
    and b.status = 'active'
  order by b.borrower_id
  limit 1;
$$;

create or replace function public.delete_equipment(p_equipment_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_equipment_manager_user() then
    raise exception 'Only equipment managers can remove equipment.';
  end if;
  if exists (
    select 1
    from public.borrowing_items bi
    join public.borrowings b on b.borrowing_id = bi.borrowing_id
    where bi.equipment_id = p_equipment_id
      and b.transaction_status in ('pending', 'approved', 'borrowed')
  ) then
    raise exception 'Equipment with an active borrowing request cannot be removed.';
  end if;
  update public.equipment
  set deleted_at = now(), deleted_by = (select auth.uid())
  where equipment_id = p_equipment_id and deleted_at is null;
  if not found then
    raise exception 'Equipment was not found or is already removed.';
  end if;
end;
$$;

create or replace function public.validate_equipment_request()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_request_count integer;
begin
  if v_user is null then
    raise exception 'Sign in before submitting an equipment request.';
  end if;
  if not public.is_verified_active_user() then
    raise exception 'Confirm your email and use an active account before submitting requests.';
  end if;
  if nullif(trim(new.purpose), '') is null or length(new.purpose) > 300 then
    raise exception 'Purpose must contain between 1 and 300 characters.';
  end if;
  if nullif(trim(new.destination), '') is null or length(new.destination) > 200 then
    raise exception 'Location must contain between 1 and 200 characters.';
  end if;
  if tg_table_name = 'reservations' then
    if new.requested_by is distinct from v_user then
      raise exception 'Reservations can only be submitted for your own account.';
    end if;
  else
    if not exists (
      select 1
      from public.borrowers b
      where b.borrower_id = new.borrower_id
        and lower(b.email) = lower((select auth.jwt() ->> 'email'))
        and b.status = 'active'
    ) then
      raise exception 'Borrowing requests can only be submitted for your own active borrower account.';
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user::text, 0));
  select count(*) into v_request_count
  from (
    select b.created_at
    from public.borrowings b
    join public.borrowers br on br.borrower_id = b.borrower_id
    where lower(br.email) = lower((select auth.jwt() ->> 'email'))
      and b.created_at >= now() - interval '10 minutes'
    union all
    select r.created_at
    from public.reservations r
    where r.requested_by = v_user
      and r.created_at >= now() - interval '10 minutes'
  ) recent_requests;

  if v_request_count >= 5 then
    raise exception 'You have submitted too many equipment requests. Wait 10 minutes before trying again.';
  end if;
  return new;
end;
$$;

revoke all on function public.validate_equipment_request() from public, anon, authenticated;

drop trigger if exists borrowing_request_validation on public.borrowings;
create trigger borrowing_request_validation
before insert on public.borrowings
for each row execute function public.validate_equipment_request();

drop trigger if exists reservation_request_validation on public.reservations;
create trigger reservation_request_validation
before insert on public.reservations
for each row execute function public.validate_equipment_request();

create or replace function public.validate_equipment_input()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if nullif(trim(new.asset_code), '') is null or length(new.asset_code) > 80 then
    raise exception 'Asset code must contain between 1 and 80 characters.';
  end if;
  if nullif(trim(new.equipment_name), '') is null or length(new.equipment_name) > 160 then
    raise exception 'Equipment name must contain between 1 and 160 characters.';
  end if;
  if coalesce(length(new.brand), 0) > 120 or coalesce(length(new.model), 0) > 120
    or coalesce(length(new.serial_number), 0) > 160
    or coalesce(length(new.storage_location), 0) > 200
    or coalesce(length(new.description), 0) > 1000 then
    raise exception 'One or more equipment fields exceed the allowed length.';
  end if;
  if new.quantity < 0 or new.quantity > 10000 then
    raise exception 'Equipment quantity must be between 0 and 10000.';
  end if;
  return new;
end;
$$;

revoke all on function public.validate_equipment_input() from public, anon, authenticated;

drop trigger if exists equipment_input_validation on public.equipment;
create trigger equipment_input_validation
before insert or update on public.equipment
for each row execute function public.validate_equipment_input();

create or replace function public.validate_profile_input()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_profile jsonb := to_jsonb(new);
  v_name text;
begin
  v_name := coalesce(
    nullif(trim(v_profile ->> 'display_name'), ''),
    nullif(trim(v_profile ->> 'full_name'), '')
  );
  if v_name is null or length(v_name) > 120 then
    raise exception 'Profile name must contain between 1 and 120 characters.';
  end if;
  if coalesce(length(v_profile ->> 'department'), 0) > 120
    or coalesce(length(v_profile ->> 'course'), 0) > 120
    or coalesce(length(v_profile ->> 'gender'), 0) > 50 then
    raise exception 'One or more profile fields exceed the allowed length.';
  end if;
  return new;
end;
$$;

revoke all on function public.validate_profile_input() from public, anon, authenticated;

drop trigger if exists profile_input_validation on public.profiles;
create trigger profile_input_validation
before insert or update on public.profiles
for each row execute function public.validate_profile_input();

create or replace function public.validate_feedback_author()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if nullif(trim(new.author_name), '') is null or length(new.author_name) > 120 then
    raise exception 'Feedback author name must contain between 1 and 120 characters.';
  end if;
  return new;
end;
$$;

revoke all on function public.validate_feedback_author() from public, anon, authenticated;

drop trigger if exists feedback_thread_author_validation on public.feedback_threads;
create trigger feedback_thread_author_validation
before insert on public.feedback_threads
for each row execute function public.validate_feedback_author();

drop trigger if exists feedback_reply_author_validation on public.feedback_replies;
create trigger feedback_reply_author_validation
before insert on public.feedback_replies
for each row execute function public.validate_feedback_author();

notify pgrst, 'reload schema';
