create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_full_name text;
  v_first_name text;
  v_last_name text;
begin
  v_full_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'New User'
  );
  v_first_name := split_part(v_full_name, ' ', 1);
  v_last_name := nullif(trim(regexp_replace(v_full_name, '^\S+\s*', '')), '');

  insert into public.profiles (id, full_name, email)
  values (new.id, v_full_name, new.email)
  on conflict (id) do nothing;

  insert into public.borrowers (
    borrower_number,
    first_name,
    last_name,
    borrower_type,
    email,
    status
  )
  values (
    'AUTO-' || upper(replace(new.id::text, '-', '')),
    v_first_name,
    coalesce(v_last_name, v_first_name),
    'student',
    new.email,
    'active'
  )
  on conflict (borrower_number) do nothing;

  return new;
end;
$$;

with users_to_profile as (
  select
    u.id,
    u.email,
    coalesce(
      nullif(trim(u.raw_user_meta_data ->> 'display_name'), ''),
      nullif(trim(u.raw_user_meta_data ->> 'full_name'), ''),
      nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
      'New User'
    ) as full_name
  from auth.users u
  where u.email is not null
)
insert into public.profiles (id, full_name, email)
select id, full_name, email
from users_to_profile
on conflict (id) do nothing;

with users_to_borrower as (
  select
    u.id,
    u.email,
    coalesce(
      nullif(trim(u.raw_user_meta_data ->> 'display_name'), ''),
      nullif(trim(u.raw_user_meta_data ->> 'full_name'), ''),
      nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
      'New User'
    ) as full_name
  from auth.users u
  where u.email is not null
)
insert into public.borrowers (
  borrower_number,
  first_name,
  last_name,
  borrower_type,
  email,
  status
)
select
  'AUTO-' || upper(replace(id::text, '-', '')),
  split_part(full_name, ' ', 1),
  coalesce(nullif(trim(regexp_replace(full_name, '^\S+\s*', '')), ''), split_part(full_name, ' ', 1)),
  'student',
  email,
  'active'
from users_to_borrower
on conflict (borrower_number) do nothing;

notify pgrst, 'reload schema';
