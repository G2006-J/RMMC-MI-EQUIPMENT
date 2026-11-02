\set ON_ERROR_STOP on

begin;

do $$
declare
  v_manager uuid;
  v_borrower_id bigint;
  v_borrower_user uuid;
  v_borrower_email text;
  v_category_id bigint;
  v_equipment_id bigint;
  v_damaged_equipment_id bigint;
  v_legacy_equipment_id bigint;
  v_available_equipment_id bigint;
  v_borrowing_id bigint;
  v_borrowing_item_id bigint;
  v_damaged_borrowing_id bigint;
  v_damaged_item_id bigint;
  v_legacy_borrowing_id bigint;
  v_legacy_item_id bigint;
  v_cancel_borrowing_id bigint;
  v_decline_borrowing_id bigint;
  v_lost_item_id bigint;
  v_available_quantity integer;
  v_audit_count integer;
  v_lock_function regprocedure;
  v_lock_marker text;
  v_function_definition text;
  v_equipment_lock_position integer;
  v_parent_lock_position integer;
begin
  select p.id
  into v_manager
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.role in ('admin', 'property_custodian')
    and p.account_status = 'active'
    and u.email_confirmed_at is not null
  order by p.created_at
  limit 1;

  select b.borrower_id, b.user_id, u.email
  into v_borrower_id, v_borrower_user, v_borrower_email
  from public.borrowers b
  join public.profiles p on p.id = b.user_id
  join auth.users u on u.id = b.user_id
  where b.status = 'active'
    and p.role = 'staff'
    and p.account_status = 'active'
    and u.email_confirmed_at is not null
  order by b.borrower_id
  limit 1;

  select category_id into v_category_id
  from public.categories
  order by category_id
  limit 1;

  if v_manager is null or v_borrower_id is null or v_category_id is null then
    raise exception 'Test requires an active manager, linked borrower, and equipment category.';
  end if;

  perform set_config('request.jwt.claim.sub', v_borrower_user::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_borrower_user, 'email', v_borrower_email)::text,
    true
  );

  insert into public.equipment (
    asset_code, equipment_name, category_id, quantity, availability_status
  )
  values (
    'WORKFLOW-' || replace(gen_random_uuid()::text, '-', ''),
    'Workflow test equipment',
    v_category_id,
    1,
    'available'
  )
  returning equipment_id into v_equipment_id;

  insert into public.equipment (
    asset_code, equipment_name, category_id, quantity, availability_status
  )
  values (
    'OVERDUE-BLOCK-' || replace(gen_random_uuid()::text, '-', ''),
    'Overdue request guard test equipment',
    v_category_id,
    1,
    'available'
  )
  returning equipment_id into v_available_equipment_id;

  insert into public.equipment (
    asset_code, equipment_name, category_id, quantity, availability_status
  )
  values (
    'DAMAGED-QUANTITY-' || replace(gen_random_uuid()::text, '-', ''),
    'Damaged quantity test equipment',
    v_category_id,
    10,
    'available'
  )
  returning equipment_id into v_damaged_equipment_id;

  insert into public.equipment (
    asset_code, equipment_name, category_id, quantity, availability_status
  )
  values (
    'LEGACY-RELEASE-' || replace(gen_random_uuid()::text, '-', ''),
    'Legacy release test equipment',
    v_category_id,
    1,
    'available'
  )
  returning equipment_id into v_legacy_equipment_id;

  insert into public.borrowings (
    transaction_code, borrower_id, processed_by, purpose, destination, expected_return_date
  )
  values (
    'CANCEL-' || replace(gen_random_uuid()::text, '-', ''),
    v_borrower_id,
    v_borrower_user,
    'Cancel SQL test',
    'Test room',
    now() + interval '1 day'
  )
  returning borrowing_id into v_cancel_borrowing_id;
  insert into public.borrowing_items (borrowing_id, equipment_id, quantity)
  values (v_cancel_borrowing_id, v_available_equipment_id, 1);

  insert into public.borrowings (
    transaction_code, borrower_id, processed_by, purpose, destination, expected_return_date
  )
  values (
    'DECLINE-' || replace(gen_random_uuid()::text, '-', ''),
    v_borrower_id,
    v_borrower_user,
    'Decline SQL test',
    'Test room',
    now() + interval '1 day'
  )
  returning borrowing_id into v_decline_borrowing_id;
  insert into public.borrowing_items (borrowing_id, equipment_id, quantity)
  values (v_decline_borrowing_id, v_available_equipment_id, 1);

  insert into public.borrowings (
    transaction_code, borrower_id, processed_by, purpose, destination, expected_return_date
  )
  values (
    'WORKFLOW-' || replace(gen_random_uuid()::text, '-', ''),
    v_borrower_id,
    v_borrower_user,
    'Workflow SQL test',
    'Test room',
    now() + interval '1 day'
  )
  returning borrowing_id into v_borrowing_id;

  insert into public.borrowing_items (borrowing_id, equipment_id, quantity)
  values (v_borrowing_id, v_equipment_id, 1)
  returning borrowing_item_id into v_borrowing_item_id;

  select available_quantity into v_available_quantity
  from public.equipment_available_quantities()
  where equipment_id = v_equipment_id;
  if v_available_quantity <> 1
    or not public.equipment_period_has_capacity(
      v_equipment_id,
      current_date,
      current_date + 1,
      1,
      null,
      null
    ) then
    raise exception 'Requested borrowings must not reduce availability or capacity.';
  end if;

  v_damaged_borrowing_id := public.request_equipment_borrowing(
    v_damaged_equipment_id,
    'Damaged unit quantity test',
    'Test room',
    now() + interval '1 day',
    1
  );
  select borrowing_item_id into v_damaged_item_id
  from public.borrowing_items
  where borrowing_id = v_damaged_borrowing_id;

  v_legacy_borrowing_id := public.request_equipment_borrowing(
    v_legacy_equipment_id,
    'Legacy already-issued test',
    'Test room',
    now() + interval '1 day',
    1
  );
  select borrowing_item_id into v_legacy_item_id
  from public.borrowing_items
  where borrowing_id = v_legacy_borrowing_id;
  update public.borrowings
  set transaction_status = 'approved'
  where borrowing_id = v_legacy_borrowing_id;
  update public.borrowing_items
  set item_status = 'approved', issued_at = now() - interval '1 hour'
  where borrowing_item_id = v_legacy_item_id;

  for v_lock_function, v_lock_marker in
    select required.function_oid, required.parent_lock
    from (values
      ('public.review_borrowing_request(bigint,text,text)'::regprocedure, 'for update;'),
      ('public.review_equipment_reservation(bigint,text,text)'::regprocedure, 'for update;'),
      ('public.cancel_my_pending_borrowing(bigint)'::regprocedure, 'for update;'),
      ('public.request_equipment_return(bigint)'::regprocedure, 'for update;'),
      ('public.release_equipment_borrowing(bigint,text,text,text)'::regprocedure, 'for update;'),
      ('public.complete_equipment_return(bigint,text,text,text)'::regprocedure, 'for update;'),
      ('public.mark_legacy_issued_borrowings_released()'::regprocedure, 'for update'),
      ('public.expire_unpicked_reservations()'::regprocedure, 'for update of r'),
      ('public.flag_overdue_borrowing_items()'::regprocedure, 'for update of b')
    ) as required(function_oid, parent_lock)
  loop
    v_function_definition := lower(pg_get_functiondef(v_lock_function));
    v_equipment_lock_position := position('for update of e' in v_function_definition);
    v_parent_lock_position := position(
      v_lock_marker
      in substring(v_function_definition from v_equipment_lock_position + 1)
    );
    if v_equipment_lock_position = 0 or v_parent_lock_position = 0 then
      raise exception 'Equipment-first row lock order is missing in function %.',
        v_lock_function;
    end if;
  end loop;

  perform public.cancel_my_pending_borrowing(v_cancel_borrowing_id);
  if (select transaction_status from public.borrowings where borrowing_id = v_cancel_borrowing_id) <> 'cancelled'
    or (select item_status from public.borrowing_items where borrowing_id = v_cancel_borrowing_id) <> 'cancelled' then
    raise exception 'Borrowers must be able to cancel only their requested borrowing.';
  end if;

  begin
    perform public.cancel_my_pending_borrowing(v_cancel_borrowing_id);
    raise exception 'Expected a cancelled borrowing to reject another cancellation.';
  exception when others then
    if sqlerrm not like '%Only your requested borrowings can be cancelled%' then
      raise;
    end if;
  end;

  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_manager)::text,
    true
  );

  if public.mark_legacy_issued_borrowings_released() <> 1
    or (select transaction_status from public.borrowings where borrowing_id = v_legacy_borrowing_id) <> 'released'
    or not exists (
      select 1 from public.borrowing_items
      where borrowing_item_id = v_legacy_item_id
        and item_status = 'released'
        and released_by = v_manager
        and released_at = (select issued_at from public.borrowing_items where borrowing_item_id = v_legacy_item_id)
    )
    or (select availability_status from public.equipment where equipment_id = v_legacy_equipment_id) <> 'borrowed' then
    raise exception 'Staff must be able to reconcile legacy issued approved borrowings as released.';
  end if;
  if public.mark_legacy_issued_borrowings_released() <> 0 then
    raise exception 'The legacy issued borrowing reconciliation must be one-time and idempotent.';
  end if;

  begin
    perform public.review_borrowing_request(v_decline_borrowing_id, 'reject', null);
    raise exception 'Expected declining without a reason to fail.';
  exception when others then
    if sqlerrm not like '%A reason is required%' then
      raise;
    end if;
  end;
  perform public.review_borrowing_request(
    v_decline_borrowing_id,
    'reject',
    'Decline reason SQL test'
  );
  if (select transaction_status from public.borrowings where borrowing_id = v_decline_borrowing_id) <> 'rejected'
    or (select decline_reason from public.borrowings where borrowing_id = v_decline_borrowing_id) <> 'Decline reason SQL test' then
    raise exception 'Declining must record the rejected status and required reason.';
  end if;

  begin
    perform public.review_borrowing_request(
      v_decline_borrowing_id,
      'reject',
      'Repeated decline test'
    );
    raise exception 'Expected a rejected borrowing to reject another decline.';
  exception when others then
    if sqlerrm not like '%no longer awaiting review%' then
      raise;
    end if;
  end;

  perform public.review_borrowing_request(v_borrowing_id, 'approve', null);
  if (select transaction_status from public.borrowings where borrowing_id = v_borrowing_id) <> 'approved'
    or (select item_status from public.borrowing_items where borrowing_item_id = v_borrowing_item_id) <> 'approved' then
    raise exception 'Approval must leave the borrowing and item in the approved state, not released.';
  end if;
  select available_quantity into v_available_quantity
  from public.equipment_available_quantities()
  where equipment_id = v_equipment_id;
  if v_available_quantity <> 0 then
    raise exception 'Approved borrowings must reduce available quantity.';
  end if;

  begin
    perform public.review_borrowing_request(v_borrowing_id, 'approve', null);
    raise exception 'Expected an approved borrowing to reject another approval.';
  exception when others then
    if sqlerrm not like '%no longer awaiting review%' then
      raise;
    end if;
  end;

  begin
    perform public.review_borrowing_request(
      v_borrowing_id,
      'reject',
      'Approved requests cannot be declined'
    );
    raise exception 'Expected an approved borrowing to reject a decline.';
  exception when others then
    if sqlerrm not like '%no longer awaiting review%' then
      raise;
    end if;
  end;

  perform public.release_equipment_borrowing(v_borrowing_id, 'good', null, null);
  if not exists (
    select 1 from public.borrowing_items
    where borrowing_item_id = v_borrowing_item_id
      and item_status = 'released'
      and released_by = v_manager
      and released_at is not null
      and condition_at_release = 'good'
  ) then
    raise exception 'Release must record the actor, timestamp, and item condition.';
  end if;

  select available_quantity into v_available_quantity
  from public.equipment_available_quantities()
  where equipment_id = v_equipment_id;
  if v_available_quantity <> 0 then
    raise exception 'A released item must reduce available stock.';
  end if;

  begin
    perform public.release_equipment_borrowing(v_borrowing_id, 'good', null, null);
    raise exception 'Expected an already released borrowing to reject another release.';
  exception when others then
    if sqlerrm not like '%Only approved borrowings can be released%' then
      raise;
    end if;
  end;

  update public.borrowings
  set expected_return_date = now() - interval '1 day'
  where borrowing_id = v_borrowing_id;

  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);
  perform public.flag_overdue_borrowing_items();

  if not exists (
    select 1 from public.borrowing_items
    where borrowing_item_id = v_borrowing_item_id and is_overdue and overdue_at is not null
  ) then
    raise exception 'The overdue job must flag released items past their return date.';
  end if;

  select available_quantity into v_available_quantity
  from public.equipment_available_quantities()
  where equipment_id = v_equipment_id;
  if v_available_quantity <> 0 then
    raise exception 'Overdue released items must continue reducing available stock.';
  end if;

  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_manager)::text,
    true
  );
  if not exists (
    select 1 from public.list_overdue_borrowings()
    where borrowing_id = v_borrowing_id
      and borrower_email = v_borrower_email
  ) then
    raise exception 'The overdue list must include the overdue borrower and contact email.';
  end if;

  update public.borrowing_items
  set is_overdue = false, overdue_at = null
  where borrowing_item_id = v_borrowing_item_id;

  perform set_config('request.jwt.claim.sub', v_borrower_user::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_borrower_user, 'email', v_borrower_email)::text,
    true
  );

  begin
    perform public.request_equipment_borrowing(
      v_available_equipment_id,
      'Overdue borrower guard test',
      'Test room',
      now() + interval '1 day',
      1
    );
    raise exception 'Expected new borrowing request to be blocked while overdue.';
  exception when others then
    if sqlerrm not like '%overdue equipment%' then
      raise;
    end if;
  end;
  if (select is_overdue from public.borrowing_items where borrowing_item_id = v_borrowing_item_id) then
    raise exception 'The live overdue request guard must not depend on the cron-maintained overdue flag.';
  end if;

  begin
    perform public.request_equipment_reservation(
      v_available_equipment_id,
      'Overdue reservation guard test',
      'Test room',
      current_date + 1,
      current_date + 2,
      1,
      time '09:00',
      time '17:00'
    );
    raise exception 'Expected new reservation request to be blocked while overdue.';
  exception when others then
    if sqlerrm not like '%overdue equipment%' then
      raise;
    end if;
  end;

  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_manager)::text,
    true
  );

  perform public.complete_equipment_return(
    v_borrowing_id,
    'damaged',
    null,
    'Test damage report description'
  );

  if not exists (
    select 1
    from public.borrowings b
    join public.borrowing_items bi using (borrowing_id)
    where b.borrowing_id = v_borrowing_id
      and b.transaction_status = 'returned'
      and bi.item_status = 'returned'
      and bi.received_by = v_manager
      and bi.returned_at is not null
      and bi.condition_at_return = 'damaged'
      and not bi.is_overdue
  ) then
    raise exception 'Return must record the receiver, timestamp, condition, and clear the overdue flag.';
  end if;

  select available_quantity into v_available_quantity
  from public.equipment_available_quantities()
  where equipment_id = v_equipment_id;
  if v_available_quantity <> 0 then
    raise exception 'Equipment returned damaged must remain unavailable pending maintenance.';
  end if;
  if (select availability_status from public.equipment where equipment_id = v_equipment_id) <> 'maintenance' then
    raise exception 'Damaged returned equipment must be placed into maintenance.';
  end if;

  begin
    perform public.complete_equipment_return(
      v_borrowing_id,
      'good',
      null,
      null
    );
    raise exception 'Expected an already returned borrowing to reject another return.';
  exception when others then
    if sqlerrm not like '%Only released borrowings can be returned%' then
      raise;
    end if;
  end;

  if not exists (
    select 1 from public.damage_loss_reports
    where borrowing_item_id = v_borrowing_item_id
      and report_type = 'damage'
      and description = 'Test damage report description'
      and resolution_status = 'open'
  ) then
    raise exception 'Damaged returns must create an open damage report.';
  end if;

  perform public.resolve_damage_loss_report(
    (select report_id from public.damage_loss_reports where borrowing_item_id = v_borrowing_item_id),
    'resolved',
    'Test resolution'
  );

  if not exists (
    select 1 from public.damage_loss_reports
    where borrowing_item_id = v_borrowing_item_id
      and resolution_status = 'resolved'
      and resolved_by = v_manager
      and resolved_at is not null
  ) then
    raise exception 'Damage report resolution must record the resolving manager and timestamp.';
  end if;

  select count(*) into v_audit_count
  from public.borrowing_workflow_audit
  where borrowing_id = v_borrowing_id
    and entity_type = 'damage_report'
    and event_type = 'status_changed';
  if v_audit_count < 2 then
    raise exception 'Damage report creation and resolution status changes must be audited.';
  end if;

  select count(*) into v_audit_count
  from public.borrowing_workflow_audit
  where borrowing_id = v_borrowing_id;
  if v_audit_count < 6 then
    raise exception 'Approval, release, overdue, and return status changes must be audited.';
  end if;

  perform public.review_borrowing_request(v_damaged_borrowing_id, 'approve', null);
  perform public.release_equipment_borrowing(v_damaged_borrowing_id, 'good', null, null);
  perform public.complete_equipment_return(
    v_damaged_borrowing_id,
    'damaged',
    null,
    'One of ten units returned damaged'
  );
  select available_quantity into v_available_quantity
  from public.equipment_available_quantities()
  where equipment_id = v_damaged_equipment_id;
  if v_available_quantity <> 9
    or (select out_of_service_quantity from public.equipment where equipment_id = v_damaged_equipment_id) <> 1
    or (select availability_status from public.equipment where equipment_id = v_damaged_equipment_id) <> 'available' then
    raise exception 'One damaged unit in quantity ten must leave nine usable units available.';
  end if;
  if not public.equipment_period_has_capacity(
    v_damaged_equipment_id,
    current_date,
    current_date + 1,
    9,
    null,
    null
  ) or public.equipment_period_has_capacity(
    v_damaged_equipment_id,
    current_date,
    current_date + 1,
    10,
    null,
    null
  ) then
    raise exception 'Damaged units must be excluded from future borrowing capacity.';
  end if;

  perform set_config('request.jwt.claim.sub', v_borrower_user::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_borrower_user, 'email', v_borrower_email)::text,
    true
  );
  v_decline_borrowing_id := public.request_equipment_borrowing(
    v_available_equipment_id,
    'Lost equipment SQL test',
    'Test room',
    now() + interval '1 day',
    1
  );
  select borrowing_item_id into v_lost_item_id
  from public.borrowing_items
  where borrowing_id = v_decline_borrowing_id;
  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_manager)::text,
    true
  );
  perform public.review_borrowing_request(v_decline_borrowing_id, 'approve', null);
  perform public.release_equipment_borrowing(v_decline_borrowing_id, 'good', null, null);
  perform public.complete_equipment_return(
    v_decline_borrowing_id,
    'lost',
    null,
    'Test lost equipment'
  );
  if (select quantity from public.equipment where equipment_id = v_available_equipment_id) <> 0
    or (select availability_status from public.equipment where equipment_id = v_available_equipment_id) <> 'retired' then
    raise exception 'Lost equipment must be removed from quantity and retired when no stock remains.';
  end if;
  if not exists (
    select 1
    from public.damage_loss_reports
    where borrowing_item_id = v_lost_item_id
      and report_type = 'loss'
      and description = 'Test lost equipment'
      and resolution_status = 'open'
  ) then
    raise exception 'Lost returns must create an open loss report.';
  end if;
end;
$$;

rollback;

do $$
begin
  raise notice 'PASS: request state flow, release/return metadata, overdue blocking, damage reporting, and status audit.';
end;
$$;
