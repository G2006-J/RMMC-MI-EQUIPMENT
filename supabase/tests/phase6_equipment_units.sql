\set ON_ERROR_STOP on

begin;

explain (analyze, buffers, costs off)
select e.equipment_id, e.equipment_name
from public.equipment e
where e.deleted_at is null
  and (lower(e.equipment_name) like 'camera%'
    or lower(e.asset_code) like 'camera%'
    or lower(coalesce(e.storage_location, '')) like 'camera%')
order by e.equipment_name, e.equipment_id
limit 20;

do $$
declare
  v_manager uuid;
  v_staff uuid;
  v_staff_email text;
  v_borrower_id bigint;
  v_category_id bigint;
  v_equipment_id bigint;
  v_other_equipment_id bigint;
  v_page_equipment_id bigint;
  v_unit_a bigint;
  v_unit_b bigint;
  v_unit_c bigint;
  v_other_unit bigint;
  v_borrowing_id bigint;
  v_item_id bigint;
  v_lost_borrowing_id bigint;
  v_lost_item_id bigint;
  v_page_one bigint[];
  v_page_two bigint[];
  v_counter integer;
  v_result jsonb;
  v_formula_code text := 'CSV-CODE-' || replace(gen_random_uuid()::text, '-', '');
  v_formula_name text := 'Formula-safe inventory';
  v_duplicate_code text := 'DUP-TAG-' || replace(gen_random_uuid()::text, '-', '');
  v_duplicate_tag text := 'CSV-UNIT-' || replace(gen_random_uuid()::text, '-', '');
begin
  select p.id into v_manager
  from public.profiles p join auth.users u on u.id = p.id
  where p.role in ('admin', 'property_custodian') and p.account_status = 'active'
    and u.email_confirmed_at is not null order by p.created_at limit 1;
  select p.id, u.email into v_staff, v_staff_email
  from public.profiles p join auth.users u on u.id = p.id
  join public.borrowers br on br.user_id = p.id
  where p.role = 'staff' and p.account_status = 'active' and br.status = 'active'
    and u.email_confirmed_at is not null order by p.created_at limit 1;
  select category_id into v_category_id from public.categories order by category_id limit 1;
  select borrower_id into v_borrower_id from public.borrowers where user_id = v_staff and status = 'active';
  if v_manager is null or v_staff is null or v_borrower_id is null or v_category_id is null then
    raise exception 'Equipment unit tests require an active manager, linked borrower, and category.';
  end if;

  if has_table_privilege('authenticated', 'public.equipment_units', 'INSERT')
    or has_table_privilege('authenticated', 'public.equipment_units', 'UPDATE')
    or has_table_privilege('authenticated', 'public.equipment_units', 'DELETE')
    or has_column_privilege('authenticated', 'public.borrowing_items', 'unit_id', 'SELECT') then
    raise exception 'Clients must not write unit rows or read unit assignment IDs directly.';
  end if;
  if exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname in (
      'equipment_units', 'unit_maintenance_log', 'equipment_unit_audit', 'equipment_import_audit'
    ) and not c.relrowsecurity
  ) then raise exception 'RLS must be enabled on every new inventory table.'; end if;
  if has_function_privilege('anon', 'public.set_equipment_unit_status(bigint,text,text,timestamp with time zone,timestamp with time zone)', 'EXECUTE')
    or exists (
      select 1 from aclexplode((select proacl from pg_proc where oid = 'public.set_equipment_unit_status(bigint,text,text,timestamp with time zone,timestamp with time zone)'::regprocedure)) acl
      where acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
    ) then raise exception 'Unit status RPC must not be executable by public or anon.'; end if;

  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_manager)::text, true);
  insert into public.equipment (asset_code, equipment_name, category_id, quantity, tracking_mode, availability_status)
  values ('UNIT-TEST-' || replace(gen_random_uuid()::text, '-', ''), 'Unit test equipment', v_category_id, 0, 'unit', 'available')
  returning equipment_id into v_equipment_id;
  insert into public.equipment (asset_code, equipment_name, category_id, quantity, tracking_mode, availability_status)
  values ('UNIT-OTHER-' || replace(gen_random_uuid()::text, '-', ''), 'Other unit test equipment', v_category_id, 0, 'unit', 'available')
  returning equipment_id into v_other_equipment_id;
  v_unit_a := public.add_equipment_unit(v_equipment_id, 'UT-A-' || replace(gen_random_uuid()::text, '-', ''));
  v_unit_b := public.add_equipment_unit(v_equipment_id, 'UT-B-' || replace(gen_random_uuid()::text, '-', ''));
  v_unit_c := public.add_equipment_unit(v_equipment_id, 'UT-C-' || replace(gen_random_uuid()::text, '-', ''));
  v_other_unit := public.add_equipment_unit(v_other_equipment_id, 'UT-X-' || replace(gen_random_uuid()::text, '-', ''));
  if public.equipment_unit_qr_payload(v_unit_a) <> (select asset_tag from public.equipment_units where unit_id = v_unit_a) then
    raise exception 'QR payload must be exactly the unit asset tag.';
  end if;

  insert into public.equipment (asset_code, equipment_name, category_id, quantity, tracking_mode, availability_status)
  values ('UNIT-PAGE-' || replace(gen_random_uuid()::text, '-', ''), 'Unit pagination fixture', v_category_id, 0, 'unit', 'available')
  returning equipment_id into v_page_equipment_id;
  for v_counter in 1..21 loop
    perform public.add_equipment_unit(v_page_equipment_id,
      'PAGE-UNIT-' || lpad(v_counter::text, 3, '0') || '-' || replace(gen_random_uuid()::text, '-', ''));
  end loop;

  perform public.set_equipment_unit_status(v_unit_a, 'maintenance', 'test maintenance', now(), now() + interval '2 days');
  begin
    perform public.set_equipment_unit_status(v_unit_a, 'maintenance', 'duplicate maintenance');
    raise exception 'A unit cannot enter maintenance twice without closing the first record.';
  exception when others then
    if sqlerrm = 'A unit cannot enter maintenance twice without closing the first record.' then raise; end if;
    if sqlerrm not like '%already in that status%' then raise; end if;
  end;
  begin
    delete from public.unit_maintenance_log where unit_id = v_unit_a and completed_at is null;
    raise exception 'An open maintenance row must not be deletable.';
  exception when others then
    if sqlerrm = 'An open maintenance row must not be deletable.' then raise; end if;
    if sqlerrm not like '%open maintenance record cannot be deleted%' then raise; end if;
  end;
  perform public.set_equipment_unit_status(v_unit_a, 'available');

  begin
    insert into public.equipment_units (equipment_id, asset_tag) values (v_equipment_id, 'DIRECT-INSERT-MUST-FAIL');
    set constraints all immediate;
    raise exception 'Direct unit insertion must not break the unit count.';
  exception when check_violation then null;
  end;
  begin
    delete from public.equipment_unit_audit where unit_id = v_unit_c;
    delete from public.equipment_units where unit_id = v_unit_c;
    set constraints all immediate;
    raise exception 'Direct unit deletion must not break the unit count.';
  exception when check_violation then null;
  end;
  begin
    update public.equipment set quantity = quantity + 1 where equipment_id = v_equipment_id;
    set constraints all immediate;
    raise exception 'Direct quantity changes must preserve the unit count.';
  exception when check_violation then null;
  end;

  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_staff, 'email', v_staff_email)::text, true);
  begin
    perform public.set_equipment_unit_status(v_unit_b, 'maintenance', 'unauthorized');
    raise exception 'Non-manager must not change unit status.';
  exception when others then
    if sqlerrm = 'Non-manager must not change unit status.' then raise; end if;
    if sqlerrm not like '%Only administrators and property custodians%' then raise; end if;
  end;
  begin
    perform public.add_equipment_unit(v_equipment_id, 'UNAUTHORIZED-UNIT');
    raise exception 'Non-manager must not add equipment units.';
  exception when others then
    if sqlerrm = 'Non-manager must not add equipment units.' then raise; end if;
    if sqlerrm not like '%Only administrators and property custodians%' then raise; end if;
  end;

  v_borrowing_id := public.request_equipment_borrowing(v_equipment_id, 'Unit test', 'Room 1', now() + interval '2 days', 1);
  select borrowing_item_id into v_item_id from public.borrowing_items where borrowing_id = v_borrowing_id;
  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_manager)::text, true);
  perform public.review_borrowing_request(v_borrowing_id, 'approve');
  begin
    perform public.release_equipment_borrowing_units(v_borrowing_id,
      jsonb_build_array(jsonb_build_object('borrowing_item_id', v_item_id, 'unit_id', v_other_unit)), 'good');
    raise exception 'A unit for different equipment must not be released to this borrowing.';
  exception when others then
    if sqlerrm = 'A unit for different equipment must not be released to this borrowing.' then raise; end if;
    if sqlerrm not like '%unknown, unavailable, or does not match%' then raise; end if;
  end;
  perform public.set_equipment_unit_status(v_unit_a, 'maintenance', 'not ready', now(), now() + interval '1 day');
  begin
    perform public.release_equipment_borrowing_units(v_borrowing_id,
      jsonb_build_array(jsonb_build_object('borrowing_item_id', v_item_id, 'unit_id', v_unit_a)), 'good');
    raise exception 'A maintenance unit must not be released.';
  exception when others then
    if sqlerrm = 'A maintenance unit must not be released.' then raise; end if;
    if sqlerrm not like '%unknown, unavailable, or does not match%' then raise; end if;
  end;
  perform public.set_equipment_unit_status(v_unit_a, 'available');
  perform public.release_equipment_borrowing_units(v_borrowing_id,
    jsonb_build_array(jsonb_build_object('borrowing_item_id', v_item_id, 'unit_id', v_unit_a)), 'good');
  begin
    perform public.release_equipment_borrowing_units(v_borrowing_id,
      jsonb_build_array(jsonb_build_object('borrowing_item_id', v_item_id, 'unit_id', v_unit_b)), 'good');
    raise exception 'A released borrowing must not be released twice.';
  exception when others then
    if sqlerrm = 'A released borrowing must not be released twice.' then raise; end if;
    if sqlerrm not like '%Only approved borrowings can be released%' then raise; end if;
  end;
  perform public.complete_equipment_unit_return(v_item_id, 'damaged',
    (select asset_tag from public.equipment_units where unit_id = v_unit_a), null, 'Damaged test unit');
  if (select status from public.equipment_units where unit_id = v_unit_a) <> 'maintenance'
    or (select count(*) from public.equipment_units where equipment_id = v_equipment_id and status = 'available') <> 2
    or (select out_of_service_quantity from public.equipment where equipment_id = v_equipment_id) <> 1 then
    raise exception 'A damaged return must affect only its own unit and increase out-of-service quantity.';
  end if;

  v_lost_borrowing_id := public.request_equipment_borrowing(v_equipment_id, 'Lost test', 'Room 2', now() + interval '2 days', 1);
  select borrowing_item_id into v_lost_item_id from public.borrowing_items where borrowing_id = v_lost_borrowing_id;
  perform public.review_borrowing_request(v_lost_borrowing_id, 'approve');
  perform public.release_equipment_borrowing_units(v_lost_borrowing_id,
    jsonb_build_array(jsonb_build_object('borrowing_item_id', v_lost_item_id, 'unit_id', v_unit_b)), 'good');
  perform public.complete_equipment_unit_return(v_lost_item_id, 'lost',
    (select asset_tag from public.equipment_units where unit_id = v_unit_b), null, 'Lost test unit');
  if (select status from public.equipment_units where unit_id = v_unit_b) <> 'lost' then
    raise exception 'A lost return must mark that unit lost.';
  end if;

  select array_agg(unit_id order by unit_id) into v_page_one
  from public.search_equipment_units_page('PAGE-UNIT-', null, 0);
  if cardinality(v_page_one) <> 20 then raise exception 'The first unit page must contain 20 rows.'; end if;
  select array_agg(unit_id order by unit_id) into v_page_two
  from public.search_equipment_units_page('PAGE-UNIT-', null, v_page_one[20]);
  if cardinality(v_page_two) <> 1 or v_page_two[1] <= v_page_one[20] or v_page_two && v_page_one then
    raise exception 'Keyset unit pages must be stable, ordered, and non-overlapping.';
  end if;

  v_result := public.import_equipment_csv(jsonb_build_array(
    jsonb_build_object('asset_code', v_formula_code, 'equipment_name', v_formula_input,
      'category_name', (select category_name from public.categories where category_id = v_category_id),
      'tracking_mode', 'quantity', 'quantity', '1')
  ), false);
  if not (v_result ->> 'ok')::boolean
    or not exists (select 1 from public.equipment where asset_code = v_formula_code and equipment_name = v_formula_name) then
    raise exception 'CSV import must strip a leading formula character before saving.';
  end if;

  v_result := public.import_equipment_csv(jsonb_build_array(
    jsonb_build_object('asset_code', 'BAD-FILE-' || gen_random_uuid(), 'equipment_name', 'Valid row',
      'category_name', (select category_name from public.categories where category_id = v_category_id),
      'tracking_mode', 'quantity', 'quantity', '1'),
    jsonb_build_object('asset_code', '', 'equipment_name', 'Invalid row', 'category_name', 'missing',
      'tracking_mode', 'quantity', 'quantity', '1')
  ), false);
  if coalesce((v_result ->> 'ok')::boolean, true) or exists (select 1 from public.equipment where asset_code like 'BAD-FILE-%') then
    raise exception 'An invalid CSV row must reject the entire import without partial data.';
  end if;

  v_result := public.import_equipment_csv(jsonb_build_array(
    jsonb_build_object('asset_code', v_duplicate_code, 'equipment_name', 'Duplicate tags',
      'category_name', (select category_name from public.categories where category_id = v_category_id),
      'tracking_mode', 'unit', 'quantity', '2', 'unit_asset_tag', v_duplicate_tag),
    jsonb_build_object('asset_code', v_duplicate_code, 'equipment_name', 'Duplicate tags',
      'category_name', (select category_name from public.categories where category_id = v_category_id),
      'tracking_mode', 'unit', 'quantity', '2', 'unit_asset_tag', v_duplicate_tag)
  ), false);
  if coalesce((v_result ->> 'ok')::boolean, true) then
    raise exception 'Duplicate unit asset tags in one import file must be rejected.';
  end if;
  v_result := public.import_equipment_csv(jsonb_build_array(
    jsonb_build_object('asset_code', 'EXISTING-TAG-' || gen_random_uuid(), 'equipment_name', 'Existing tag collision',
      'category_name', (select category_name from public.categories where category_id = v_category_id),
      'tracking_mode', 'unit', 'quantity', '1', 'unit_asset_tag',
      (select asset_tag from public.equipment_units where unit_id = v_unit_a))
  ), false);
  if coalesce((v_result ->> 'ok')::boolean, true) then
    raise exception 'A unit tag already present in the database must be rejected.';
  end if;
  begin
    perform public.import_equipment_csv((
      select jsonb_agg(jsonb_build_object('asset_code', 'LIMIT-' || value, 'quantity', '1'))
      from generate_series(1, 501) as rows(value)
    ), true);
    raise exception 'CSV import must enforce the 500 row cap.';
  exception when others then
    if sqlerrm = 'CSV import must enforce the 500 row cap.' then raise; end if;
    if sqlerrm not like '%between 1 and 500%' then raise; end if;
  end;
  begin
    perform public.import_equipment_csv(jsonb_build_array(jsonb_build_object('notes', repeat('x', 1048576))), true);
    raise exception 'CSV import must enforce the 1 MB payload cap.';
  exception when others then
    if sqlerrm = 'CSV import must enforce the 1 MB payload cap.' then raise; end if;
    if sqlerrm not like '%cannot exceed 1 MB%' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_staff, 'email', v_staff_email)::text, true);
  begin
    perform public.import_equipment_csv('[]'::jsonb, true);
    raise exception 'Non-admin users must not import equipment.';
  exception when others then
    if sqlerrm = 'Non-admin users must not import equipment.' then raise; end if;
    if sqlerrm not like '%Only administrators can import equipment%' then raise; end if;
  end;
end;
$$;

set constraints all immediate;
rollback;
