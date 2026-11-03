\set ON_ERROR_STOP on
begin;

do $$
declare
  v_admin uuid;
  v_user uuid;
  v_equipment bigint;
  v_session_count integer;
  v_photo_path text;
begin
  select p.id into v_admin
  from public.profiles p
  where p.email = 'ci-admin@example.com' and p.role = 'admin' and p.account_status = 'active';
  select p.id into v_user
  from public.profiles p
  where p.email = 'ci-phase8@example.com' and p.role = 'staff' and p.account_status = 'active';
  select e.equipment_id into v_equipment from public.equipment e order by e.equipment_id limit 1;
  if v_admin is null or v_user is null or v_equipment is null then
    raise exception 'Phase 8 SQL test fixtures are missing.';
  end if;
  if not exists (
    select 1 from public.privacy_notice_acceptances a
    where a.user_id = v_user and a.notice_version = '2026-11-03-v1' and a.accepted_at is not null
  ) then
    raise exception 'Signup must store versioned privacy notice acceptance.';
  end if;
  select count(*) into v_session_count from auth.sessions s where s.user_id = v_user;
  if v_session_count = 0 then raise exception 'Phase 8 test requires an active auth session.'; end if;

  update public.profiles set profile_photo_path = v_user::text || '/phase8.webp' where id = v_user;
  update public.borrowers set profile_photo_path = v_user::text || '/phase8.webp' where user_id = v_user;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  perform public.admin_deactivate_borrower_account(v_user);

  if (not exists (select 1 from public.profiles p where p.id = v_user and p.account_status = 'inactive'))
    or not exists (select 1 from public.borrowers b where b.user_id = v_user and b.status = 'inactive') then
    raise exception 'Deactivation must mark the profile and borrower inactive.';
  end if;
  if exists (select 1 from auth.sessions s where s.user_id = v_user) then
    raise exception 'Deactivation must delete existing auth sessions.';
  end if;
  if not exists (
    select 1 from public.phase7_audit_log a
    where a.event_type = 'profile_access_changed' and a.entity_id = v_user::text
      and a.actor_id = v_admin and a.before_values->>'account_status' = 'active'
      and a.after_values->>'account_status' = 'inactive'
  ) then
    raise exception 'Deactivation must create a canonical account-access audit row.';
  end if;

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  if public.is_verified_active_user() then raise exception 'Inactive account passed active-user validation.'; end if;
  begin
    perform public.request_equipment_borrowing(v_equipment, 'Phase 8 test', 'Room 8', now() + interval '1 day', 1);
    raise exception 'Inactive account unexpectedly created a borrowing request.';
  exception when raise_exception then
    if sqlerrm = 'Inactive account unexpectedly created a borrowing request.' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  v_photo_path := public.admin_anonymize_inactive_borrower(v_user);
  if v_photo_path is distinct from v_user::text || '/phase8.webp' then
    raise exception 'Anonymization must return the old profile photo path for app-side deletion.';
  end if;
  if not exists (
    select 1 from public.profiles p
    where p.id = v_user and p.full_name = 'Anonymized account' and p.first_name = 'Anonymized'
      and p.last_name = 'User' and p.email = '' and p.department is null and p.course is null
      and p.gender is null and p.profile_photo_path is null and p.account_status = 'inactive'
  ) or not exists (
    select 1 from public.borrowers b
    where b.user_id = v_user and b.first_name = 'Anonymized' and b.middle_name is null
      and b.last_name = 'User' and b.email = '' and b.department is null and b.course is null
      and b.gender is null and b.profile_photo_path is null and b.status = 'inactive'
  ) then
    raise exception 'Anonymization must clear borrower and profile personal fields while retaining account rows.';
  end if;

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user, 'role', 'authenticated')::text, true);
end;
$$;

set local role authenticated;
do $$
begin
  if exists (select 1 from public.profiles where id = (select auth.uid()))
    or exists (select 1 from public.notifications where user_id = (select auth.uid()))
    or exists (select 1 from public.borrower_agreement_acceptances where user_id = (select auth.uid()))
    or exists (select 1 from public.privacy_notice_acceptances where user_id = (select auth.uid())) then
    raise exception 'Inactive accounts must not read own profile, notifications, or acceptance records.';
  end if;
end;
$$;
reset role;

rollback;