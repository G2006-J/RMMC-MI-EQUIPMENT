alter table public.profiles
  add column if not exists first_name text not null default '',
  add column if not exists last_name text not null default '';

update public.profiles p
set first_name = coalesce(
      (select nullif(trim(b.first_name), '')
       from public.borrowers b
       where lower(b.email) = lower(p.email)
       order by b.borrower_id
       limit 1),
      nullif(split_part(trim(p.full_name), ' ', 1), ''),
      'Member'
    ),
    last_name = coalesce(
      (select nullif(trim(b.last_name), '')
       from public.borrowers b
       where lower(b.email) = lower(p.email)
       order by b.borrower_id
       limit 1),
      nullif(trim(regexp_replace(trim(p.full_name), '^\S+\s*', '')), ''),
      'Member'
    )
where p.first_name = '' or p.last_name = '';

create or replace function public.update_my_account_profile(
  p_first_name text,
  p_last_name text,
  p_department text,
  p_course text,
  p_gender text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_borrower_id bigint;
begin
  if not public.is_verified_active_user() then
    raise exception 'Sign in with a verified, active account to update your profile.';
  end if;
  if nullif(trim(p_first_name), '') is null or length(trim(p_first_name)) > 60
    or nullif(trim(p_last_name), '') is null or length(trim(p_last_name)) > 60
    or length(trim(p_first_name)) + length(trim(p_last_name)) + 1 > 120 then
    raise exception 'First and last names are required, must be 60 characters or fewer, and cannot exceed 120 characters combined.';
  end if;
  if coalesce(length(trim(p_department)), 0) > 120
    or coalesce(length(trim(p_course)), 0) > 120
    or coalesce(length(trim(p_gender)), 0) > 50 then
    raise exception 'One or more profile fields exceed the allowed length.';
  end if;

  update public.profiles
  set first_name = trim(p_first_name),
      last_name = trim(p_last_name),
      full_name = concat_ws(' ', trim(p_first_name), trim(p_last_name)),
      department = nullif(trim(p_department), ''),
      course = nullif(trim(p_course), ''),
      gender = nullif(trim(p_gender), ''),
      updated_at = now()
  where id = (select auth.uid());
  if not found then
    raise exception 'Your profile could not be found.';
  end if;

  v_borrower_id := public.current_borrower_id();
  if v_borrower_id is not null then
    update public.borrowers
    set first_name = trim(p_first_name),
        last_name = trim(p_last_name),
        department = nullif(trim(p_department), ''),
        course = nullif(trim(p_course), ''),
        gender = nullif(trim(p_gender), '')
    where borrower_id = v_borrower_id;
  end if;
end;
$$;

revoke all on function public.update_my_account_profile(text, text, text, text, text) from public, anon;
grant execute on function public.update_my_account_profile(text, text, text, text, text) to authenticated;

revoke select on public.borrowers from authenticated;
grant select (borrower_id, first_name, middle_name, last_name, email, department, status)
  on public.borrowers to authenticated;

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_display_name text;
  v_first_name text;
  v_last_name text;
  v_department text;
  v_course text;
  v_gender text;
begin
  v_first_name := nullif(trim(new.raw_user_meta_data ->> 'first_name'), '');
  v_last_name := nullif(trim(new.raw_user_meta_data ->> 'last_name'), '');
  v_display_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(concat_ws(' ', v_first_name, v_last_name), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'New User'
  );
  v_first_name := coalesce(v_first_name, nullif(split_part(v_display_name, ' ', 1), ''), 'Member');
  v_last_name := coalesce(
    v_last_name,
    nullif(trim(regexp_replace(v_display_name, '^\S+\s*', '')), ''),
    v_first_name
  );
  v_department := nullif(trim(new.raw_user_meta_data ->> 'department'), '');
  v_course := nullif(trim(new.raw_user_meta_data ->> 'course'), '');
  v_gender := nullif(trim(new.raw_user_meta_data ->> 'gender'), '');

  insert into public.profiles (
    id, full_name, first_name, last_name, email, department, course, gender
  )
  values (
    new.id, concat_ws(' ', v_first_name, v_last_name), v_first_name, v_last_name,
    new.email, v_department, v_course, v_gender
  )
  on conflict (id) do update set
    full_name = excluded.full_name,
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    email = excluded.email,
    department = excluded.department,
    course = excluded.course,
    gender = excluded.gender;

  insert into public.borrowers (
    borrower_number, first_name, last_name, borrower_type, email,
    department, course, gender, status
  )
  values (
    'AUTO-' || upper(replace(new.id::text, '-', '')),
    v_first_name, v_last_name, 'student', new.email,
    v_department, v_course, v_gender, 'active'
  )
  on conflict (borrower_number) do update set
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    email = excluded.email,
    department = excluded.department,
    course = excluded.course,
    gender = excluded.gender;

  return new;
end;
$$;

drop policy if exists "read verified borrower records" on public.borrowers;
create policy "read verified borrower records" on public.borrowers for select to authenticated
using (
  public.is_verified_active_user()
  and (
    lower(email) = lower((select auth.jwt() ->> 'email'))
    or public.is_equipment_manager_user()
  )
);

drop policy if exists "read verified relevant borrowings" on public.borrowings;
create policy "read verified relevant borrowings" on public.borrowings for select to authenticated
using (
  public.is_verified_active_user()
  and (borrower_id = public.current_borrower_id() or public.is_equipment_manager_user())
);

drop policy if exists "read verified relevant borrowing items" on public.borrowing_items;
create policy "read verified relevant borrowing items" on public.borrowing_items for select to authenticated
using (
  public.is_verified_active_user()
  and exists (
    select 1
    from public.borrowings b
    where b.borrowing_id = borrowing_items.borrowing_id
      and (
        b.borrower_id = public.current_borrower_id()
        or public.is_equipment_manager_user()
      )
  )
);

drop policy if exists "read verified relevant reservations" on public.reservations;
create policy "read verified relevant reservations" on public.reservations for select to authenticated
using (
  public.is_verified_active_user()
  and (requested_by = (select auth.uid()) or public.is_equipment_manager_user())
);

drop policy if exists "read verified relevant return requests" on public.return_requests;
create policy "read verified relevant return requests" on public.return_requests for select to authenticated
using (
  public.is_verified_active_user()
  and (requested_by = (select auth.uid()) or public.is_equipment_manager_user())
);

notify pgrst, 'reload schema';
