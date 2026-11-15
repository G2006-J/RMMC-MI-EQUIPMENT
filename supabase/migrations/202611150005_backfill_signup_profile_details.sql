begin;

with signup_details as (
  select
    u.id,
    nullif(trim(u.raw_user_meta_data ->> 'first_name'), '') as metadata_first_name,
    nullif(trim(u.raw_user_meta_data ->> 'last_name'), '') as metadata_last_name,
    coalesce(
      nullif(trim(u.raw_user_meta_data ->> 'display_name'), ''),
      nullif(trim(u.raw_user_meta_data ->> 'full_name'), ''),
      nullif(concat_ws(
        ' ',
        nullif(trim(u.raw_user_meta_data ->> 'first_name'), ''),
        nullif(trim(u.raw_user_meta_data ->> 'last_name'), '')
      ), ''),
      nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
      'New User'
    ) as display_name,
    nullif(trim(u.raw_user_meta_data ->> 'department'), '') as metadata_department,
    nullif(trim(u.raw_user_meta_data ->> 'course'), '') as metadata_course,
    nullif(trim(u.raw_user_meta_data ->> 'gender'), '') as metadata_gender,
    nullif(trim(b.first_name), '') as borrower_first_name,
    nullif(trim(b.last_name), '') as borrower_last_name,
    nullif(trim(b.department), '') as borrower_department,
    nullif(trim(b.course), '') as borrower_course,
    nullif(trim(b.gender), '') as borrower_gender
  from auth.users u
  left join public.borrowers b on b.user_id = u.id
),
normalized_details as (
  select
    id,
    coalesce(metadata_first_name, nullif(split_part(display_name, ' ', 1), ''), 'Member') as first_name,
    coalesce(
      metadata_last_name,
      nullif(trim(regexp_replace(display_name, '^\S+\s*', '')), ''),
      metadata_first_name,
      nullif(split_part(display_name, ' ', 1), ''),
      'Member'
    ) as last_name,
    coalesce(borrower_first_name, metadata_first_name) as borrower_first_name,
    coalesce(borrower_last_name, metadata_last_name) as borrower_last_name,
    metadata_department,
    metadata_course,
    metadata_gender,
    borrower_department,
    borrower_course,
    borrower_gender
  from signup_details
)
update public.profiles p
set first_name = coalesce(nullif(trim(p.first_name), ''), n.borrower_first_name, n.first_name),
    last_name = coalesce(nullif(trim(p.last_name), ''), n.borrower_last_name, n.last_name),
    full_name = coalesce(
      nullif(trim(p.full_name), ''),
      concat_ws(
        ' ',
        coalesce(nullif(trim(p.first_name), ''), n.borrower_first_name, n.first_name),
        coalesce(nullif(trim(p.last_name), ''), n.borrower_last_name, n.last_name)
      )
    ),
    department = coalesce(nullif(trim(p.department), ''), n.borrower_department, n.metadata_department),
    course = coalesce(nullif(trim(p.course), ''), n.borrower_course, n.metadata_course),
    gender = coalesce(nullif(trim(p.gender), ''), n.borrower_gender, n.metadata_gender),
    updated_at = now()
from normalized_details n
where p.id = n.id
  and p.account_status in ('pending', 'active')
  and (
    nullif(trim(p.first_name), '') is null
    or nullif(trim(p.last_name), '') is null
    or nullif(trim(p.full_name), '') is null
    or (nullif(trim(p.department), '') is null and coalesce(n.borrower_department, n.metadata_department) is not null)
    or (nullif(trim(p.course), '') is null and coalesce(n.borrower_course, n.metadata_course) is not null)
    or (nullif(trim(p.gender), '') is null and coalesce(n.borrower_gender, n.metadata_gender) is not null)
  );

update public.borrowers b
set first_name = coalesce(nullif(trim(b.first_name), ''), nullif(trim(p.first_name), '')),
    last_name = coalesce(nullif(trim(b.last_name), ''), nullif(trim(p.last_name), '')),
    department = coalesce(nullif(trim(b.department), ''), nullif(trim(p.department), '')),
    course = coalesce(nullif(trim(b.course), ''), nullif(trim(p.course), '')),
    gender = coalesce(nullif(trim(b.gender), ''), nullif(trim(p.gender), ''))
from public.profiles p
where b.user_id = p.id
  and p.account_status in ('pending', 'active')
  and (
    (nullif(trim(b.first_name), '') is null and nullif(trim(p.first_name), '') is not null)
    or (nullif(trim(b.last_name), '') is null and nullif(trim(p.last_name), '') is not null)
    or (nullif(trim(b.department), '') is null and nullif(trim(p.department), '') is not null)
    or (nullif(trim(b.course), '') is null and nullif(trim(p.course), '') is not null)
    or (nullif(trim(b.gender), '') is null and nullif(trim(p.gender), '') is not null)
  );

commit;
