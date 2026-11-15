\set ON_ERROR_STOP on
begin;

do $$
declare
  v_admin uuid;
  v_custodian uuid;
  v_staff uuid;
  v_staff_email text;
  v_category_id bigint;
  v_equipment_id bigint;
begin
  select p.id into v_admin
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.role = 'admin' and p.account_status = 'active' and u.email_confirmed_at is not null
  order by p.created_at limit 1;
  select p.id into v_custodian
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.role = 'property_custodian' and p.account_status = 'active' and u.email_confirmed_at is not null
  order by p.created_at limit 1;
  select p.id, u.email into v_staff, v_staff_email
  from public.profiles p
  join auth.users u on u.id = p.id
  join public.borrowers b on b.user_id = p.id
  where p.role = 'staff' and p.account_status = 'active' and b.status = 'active'
    and u.email_confirmed_at is not null
  order by p.created_at limit 1;
  select c.category_id into v_category_id from public.categories c order by c.category_id limit 1;
  if v_admin is null or v_custodian is null or v_staff is null or v_category_id is null then
    raise exception 'Role permission tests require active admin, property custodian, borrower, and category fixtures.';
  end if;

  insert into public.equipment (asset_code, equipment_name, category_id, quantity, tracking_mode, availability_status)
  values ('ROLE-PERM-' || replace(gen_random_uuid()::text, '-', ''), 'Role permission test equipment',
    v_category_id, 0, 'unit', 'available')
  returning equipment_id into v_equipment_id;
  perform set_config('role_permissions.admin_id', v_admin::text, true);
  perform set_config('role_permissions.custodian_id', v_custodian::text, true);
  perform set_config('role_permissions.staff_id', v_staff::text, true);
  perform set_config('role_permissions.staff_email', v_staff_email, true);
  perform set_config('role_permissions.equipment_id', v_equipment_id::text, true);
end;
$$;

select set_config('request.jwt.claim.sub', current_setting('role_permissions.custodian_id'), true);
select set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('role_permissions.custodian_id'),
  'role', 'authenticated'
)::text, true);
set local role authenticated;

do $$
declare
  v_equipment_id bigint := current_setting('role_permissions.equipment_id')::bigint;
  v_custodian uuid := current_setting('role_permissions.custodian_id')::uuid;
  v_staff uuid := current_setting('role_permissions.staff_id')::uuid;
  v_admin uuid := current_setting('role_permissions.admin_id')::uuid;
  v_staff_email text := current_setting('role_permissions.staff_email');
  v_rows integer;
  v_unit_id bigint;
  v_second_unit_id bigint;
  v_borrowing_id bigint;
  v_item_id bigint;
  v_asset_tag text;
  v_admin_count integer;
  v_error text;
begin
  update public.equipment set description = 'custodian write must be denied'
  where equipment_id = v_equipment_id;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then raise exception 'A property custodian updated the equipment catalog directly.'; end if;

  begin
    insert into public.equipment (asset_code, equipment_name, category_id, quantity)
    values ('CUSTODIAN-INSERT-MUST-FAIL', 'Unauthorized catalog insert',
      (select category_id from public.equipment where equipment_id = v_equipment_id), 1);
    raise exception 'A property custodian inserted equipment directly.';
  exception when insufficient_privilege then null;
  end;

  delete from public.equipment where equipment_id = v_equipment_id;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then raise exception 'A property custodian deleted catalog equipment directly.'; end if;

  if exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname in (
        'equipment managers upload images',
        'equipment managers update images',
        'equipment managers delete images'
      )
  ) or (
    select count(*) from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname in (
        'admins upload equipment images',
        'admins update equipment images',
        'admins delete equipment images'
      )
      and coalesce(qual, '') || coalesce(with_check, '') like '%is_equipment_admin_user%'
  ) <> 3 then
    raise exception 'Equipment image write policies must be admin-only.';
  end if;

  begin
    perform public.delete_equipment(v_equipment_id);
    raise exception 'A property custodian called delete_equipment.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'A property custodian called delete_equipment.' then raise; end if;
    if v_error not like '%Only administrators can remove equipment%' then raise; end if;
  end;
  begin
    perform public.convert_equipment_to_unit_tracking(v_equipment_id, '[]'::jsonb);
    raise exception 'A property custodian converted catalog equipment.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'A property custodian converted catalog equipment.' then raise; end if;
    if v_error not like '%Only administrators can convert equipment%' then raise; end if;
  end;

  v_unit_id := public.add_equipment_unit(v_equipment_id, 'ROLE-UNIT-' || replace(gen_random_uuid()::text, '-', ''));
  v_second_unit_id := public.add_equipment_unit(v_equipment_id, 'ROLE-UNIT-' || replace(gen_random_uuid()::text, '-', ''));
  perform public.set_equipment_unit_status(v_second_unit_id, 'maintenance', 'permission test');
  perform public.set_equipment_unit_status(v_second_unit_id, 'available');
  select asset_tag into v_asset_tag from public.equipment_units where unit_id = v_unit_id;

  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_staff, 'email', v_staff_email, 'role', 'authenticated'
  )::text, true);
  v_borrowing_id := public.request_equipment_borrowing(
    v_equipment_id, 'Role permission test', 'Role test location', now() + interval '2 days', 1
  );
  select borrowing_item_id into v_item_id
  from public.borrowing_items where borrowing_id = v_borrowing_id;

  perform set_config('request.jwt.claim.sub', v_custodian::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_custodian, 'role', 'authenticated'
  )::text, true);
  perform public.review_borrowing_request(v_borrowing_id, 'approve', null);
  perform public.release_equipment_borrowing_units(
    v_borrowing_id,
    jsonb_build_array(jsonb_build_object('borrowing_item_id', v_item_id, 'unit_id', v_unit_id)),
    'good'
  );
  perform public.complete_equipment_unit_return(v_item_id, 'good', v_asset_tag, null, null);
  if not exists (
    select 1 from public.borrowing_items
    where borrowing_item_id = v_item_id and item_status = 'returned' and returned_at is not null
  ) then raise exception 'A property custodian could not complete the release-and-return workflow.'; end if;

  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_staff, 'email', v_staff_email, 'role', 'authenticated'
  )::text, true);
  update public.equipment set description = 'staff write must be denied'
  where equipment_id = v_equipment_id;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then raise exception 'Staff updated the equipment catalog directly.'; end if;
  begin
    insert into public.equipment (asset_code, equipment_name, category_id, quantity)
    values ('STAFF-INSERT-MUST-FAIL', 'Unauthorized catalog insert',
      (select category_id from public.equipment where equipment_id = v_equipment_id), 1);
    raise exception 'Staff inserted equipment directly.';
  exception when insufficient_privilege then null;
  end;
  delete from public.equipment where equipment_id = v_equipment_id;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then raise exception 'Staff deleted catalog equipment directly.'; end if;
  begin
    perform public.delete_equipment(v_equipment_id);
    raise exception 'Staff called delete_equipment.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called delete_equipment.' then raise; end if;
    if v_error not like '%Only administrators can remove equipment%' then raise; end if;
  end;
  begin
    perform public.convert_equipment_to_unit_tracking(v_equipment_id, '[]'::jsonb);
    raise exception 'Staff converted catalog equipment.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff converted catalog equipment.' then raise; end if;
    if v_error not like '%Only administrators can convert equipment%' then raise; end if;
  end;
  begin
    perform public.add_equipment_unit(v_equipment_id, 'STAFF-UNIT-MUST-FAIL');
    raise exception 'Staff called add_equipment_unit.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called add_equipment_unit.' then raise; end if;
    if v_error not like '%Only administrators and property custodians%' then raise; end if;
  end;
  begin
    perform public.set_equipment_unit_status(v_second_unit_id, 'maintenance', 'unauthorized');
    raise exception 'Staff called set_equipment_unit_status.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called set_equipment_unit_status.' then raise; end if;
    if v_error not like '%Only administrators and property custodians%' then raise; end if;
  end;
  begin
    perform public.release_equipment_borrowing_units(v_borrowing_id, '[]'::jsonb, 'good');
    raise exception 'Staff called release_equipment_borrowing_units.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called release_equipment_borrowing_units.' then raise; end if;
    if v_error not like '%Only administrators and property custodians%' then raise; end if;
  end;
  begin
    perform public.complete_equipment_unit_return(v_item_id, 'good', v_asset_tag, null, null);
    raise exception 'Staff called complete_equipment_unit_return.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called complete_equipment_unit_return.' then raise; end if;
    if v_error not like '%Only administrators and property custodians%' then raise; end if;
  end;
  begin
    perform public.review_equipment_reservation(-1, 'approve', null);
    raise exception 'Staff called review_equipment_reservation.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called review_equipment_reservation.' then raise; end if;
    if v_error not like '%Only administrators and property custodians%' then raise; end if;
  end;
  begin
    perform public.mark_reservation_picked_up(-1);
    raise exception 'Staff called mark_reservation_picked_up.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called mark_reservation_picked_up.' then raise; end if;
    if v_error not like '%Only administrators and property custodians%' then raise; end if;
  end;
  begin
    perform public.set_profile_role(v_staff, 'admin');
    raise exception 'Staff called set_profile_role.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called set_profile_role.' then raise; end if;
    if v_error not like '%Only an active administrator%' then raise; end if;
  end;
  begin
    perform public.admin_update_profile_access(v_staff, 'admin', 'active');
    raise exception 'Staff called admin_update_profile_access.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called admin_update_profile_access.' then raise; end if;
    if v_error not like '%Only an active administrator%' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_admin, 'role', 'authenticated'
  )::text, true);
  select count(*) into v_admin_count from public.profiles
  where role = 'admin' and account_status = 'active';
  begin
    perform public.admin_update_profile_access(v_admin, 'staff', 'inactive');
    raise exception 'An admin changed their own role or status.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'An admin changed their own role or status.' then raise; end if;
    if v_admin_count = 1 and v_error not like '%last active administrator%' then raise; end if;
    if v_admin_count > 1 and v_error not like '%cannot change their own role or account status%' then raise; end if;
  end;
  begin
    perform public.set_profile_role(v_admin, 'property_custodian');
    raise exception 'An admin demoted themselves.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'An admin demoted themselves.' then raise; end if;
    if v_admin_count = 1 and v_error not like '%last active administrator%' then raise; end if;
    if v_admin_count > 1 and v_error not like '%cannot change their own role or account status%' then raise; end if;
  end;
  if not exists (
    select 1 from public.profiles where id = v_admin and role = 'admin' and account_status = 'active'
  ) then raise exception 'An admin self-change attempt modified the active admin.'; end if;

  perform public.set_profile_role(v_staff, 'property_custodian');
  if not exists (
    select 1 from public.profiles p join public.borrowers b on b.user_id = p.id
    where p.id = v_staff and p.role = 'property_custodian' and b.status = p.account_status
  ) then raise exception 'set_profile_role must keep the linked borrower status synchronized.'; end if;
  perform public.admin_update_profile_access(v_staff, 'staff', 'inactive');
  if not exists (
    select 1 from public.profiles p join public.borrowers b on b.user_id = p.id
    where p.id = v_staff and p.role = 'staff' and p.account_status = 'inactive' and b.status = 'inactive'
  ) then raise exception 'admin_update_profile_access must synchronize the borrower status.'; end if;
end;
$$;

reset role;

update public.profiles
set full_name = 'Anonymized account', email = ''
where id = current_setting('role_permissions.staff_id')::uuid;
select set_config('request.jwt.claim.sub', current_setting('role_permissions.admin_id'), true);
select set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('role_permissions.admin_id'),
  'role', 'authenticated'
)::text, true);
set local role authenticated;
do $$
declare
  v_staff uuid := current_setting('role_permissions.staff_id')::uuid;
  v_error text;
begin
  begin
    perform public.admin_update_profile_access(v_staff, 'staff', 'active');
    raise exception 'An anonymized account had its access changed.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'An anonymized account had its access changed.' then raise; end if;
    if v_error not like '%Anonymized accounts cannot have their access changed%' then raise; end if;
  end;
end;
$$;
reset role;
rollback;
