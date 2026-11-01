create extension if not exists pgcrypto;

alter table public.profiles
  add column if not exists department text,
  add column if not exists course text,
  add column if not exists gender text;

alter table public.borrowers
  add column if not exists department text,
  add column if not exists course text,
  add column if not exists gender text;

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_display_name text;
  v_department text;
  v_course text;
  v_gender text;
begin
  v_display_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'New User'
  );
  v_department := nullif(trim(new.raw_user_meta_data ->> 'department'), '');
  v_course := nullif(trim(new.raw_user_meta_data ->> 'course'), '');
  v_gender := nullif(trim(new.raw_user_meta_data ->> 'gender'), '');

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'profiles' and column_name = 'display_name'
  ) then
    insert into public.profiles (id, display_name, email, department, course, gender)
    values (new.id, v_display_name, new.email, v_department, v_course, v_gender)
    on conflict (id) do update set
      display_name = excluded.display_name,
      email = excluded.email,
      department = excluded.department,
      course = excluded.course,
      gender = excluded.gender;
  else
    insert into public.profiles (id, full_name, email, department, course, gender)
    values (new.id, v_display_name, new.email, v_department, v_course, v_gender)
    on conflict (id) do update set
      full_name = excluded.full_name,
      email = excluded.email,
      department = excluded.department,
      course = excluded.course,
      gender = excluded.gender;
  end if;

  insert into public.borrowers (
    borrower_number,
    first_name,
    last_name,
    borrower_type,
    email,
    department,
    course,
    gender,
    status
  )
  values (
    'AUTO-' || upper(replace(new.id::text, '-', '')),
    split_part(v_display_name, ' ', 1),
    coalesce(nullif(trim(regexp_replace(v_display_name, '^\S+\s*', '')), ''), split_part(v_display_name, ' ', 1)),
    'student',
    new.email,
    v_department,
    v_course,
    v_gender,
    'active'
  )
  on conflict (borrower_number) do update set
    email = excluded.email,
    department = excluded.department,
    course = excluded.course,
    gender = excluded.gender;

  return new;
end;
$$;

revoke all on public.profiles from anon, authenticated;
revoke all on public.borrowers from anon, authenticated;

grant select on public.profiles, public.borrowers to authenticated;
grant update (full_name, department, course, gender) on public.profiles to authenticated;

drop trigger if exists on_auth_user_created_equipment_profile on auth.users;
create trigger on_auth_user_created_equipment_profile
  after insert on auth.users
  for each row execute function public.create_profile_for_new_user();

notify pgrst, 'reload schema';
