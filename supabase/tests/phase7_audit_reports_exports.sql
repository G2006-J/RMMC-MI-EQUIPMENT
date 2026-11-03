\set ON_ERROR_STOP on
begin;

do $$
declare
  v_admin uuid;
  v_custodian uuid;
  v_staff uuid;
  v_borrower bigint;
  v_unlinked bigint;
  v_category bigint;
  v_equipment bigint;
  v_unit_equipment bigint;
  v_unit bigint;
  v_approve bigint;
  v_approve_two bigint;
  v_decline bigint;
  v_item bigint;
  v_thread bigint;
  v_reply bigint;
  v_version bigint;
  v_result jsonb;
  v_start date := current_date - 30;
  v_end date := current_date;
  v_count integer;
  v_table text;
  v_set text;
  v_trigger text;
  v_code text := 'P7-' || replace(gen_random_uuid()::text, '-', '');
begin
  select p.id into v_admin from public.profiles p join auth.users u on u.id=p.id
    where p.role='admin' and p.account_status='active' and u.email_confirmed_at is not null order by p.created_at limit 1;
  select p.id into v_custodian from public.profiles p join auth.users u on u.id=p.id
    where p.role='property_custodian' and p.account_status='active' and u.email_confirmed_at is not null order by p.created_at limit 1;
  select p.id into v_staff from public.profiles p join auth.users u on u.id=p.id join public.borrowers br on br.user_id=p.id
    where p.role='staff' and p.account_status='active' and br.status='active' and u.email_confirmed_at is not null order by p.created_at limit 1;
  select borrower_id into v_borrower from public.borrowers where user_id=v_staff;
  select category_id into v_category from public.categories order by category_id limit 1;
  if v_admin is null or v_custodian is null or v_staff is null or v_borrower is null or v_category is null then
    raise exception 'Phase 7 SQL tests need active admin, custodian, linked staff, and category fixtures.';
  end if;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin)::text,true);

  insert into public.borrowers(borrower_number,first_name,last_name,borrower_type,email,status)
    values(v_code,'Unlinked','Borrower','student',v_code||'@example.invalid','active') returning borrower_id into v_unlinked;
  insert into public.equipment(asset_code,equipment_name,category_id,quantity,availability_status)
    values(v_code,'Phase 7 event fixture',v_category,20,'available') returning equipment_id into v_equipment;
  insert into public.borrowings(transaction_code,borrower_id,processed_by,purpose,destination,expected_return_date)
    values(v_code||'-A',v_unlinked,v_admin,'fixture','Room 1',now()+interval '5 days') returning borrowing_id into v_approve;
  insert into public.borrowing_items(borrowing_id,equipment_id,item_status,quantity) values(v_approve,v_equipment,'requested',1);
  insert into public.borrowings(transaction_code,borrower_id,processed_by,purpose,destination,expected_return_date)
    values(v_code||'-A2',v_unlinked,v_admin,'fixture','Room 1',now()+interval '5 days') returning borrowing_id into v_approve_two;
  insert into public.borrowing_items(borrowing_id,equipment_id,item_status,quantity) values(v_approve_two,v_equipment,'requested',1);
  perform public.review_borrowing_request(v_approve,'approve');
  perform public.review_borrowing_request(v_approve_two,'approve');
  select count(*) into v_count from public.phase7_audit_log
  where event_type='request_approved' and actor_id=v_admin and entity_id in (v_approve::text,v_approve_two::text);
  if v_count<>2
    or (select count(*) from public.phase7_audit_log where event_type='request_approved' and entity_id=v_approve::text and actor_id=v_admin)<>1
    or (select count(*) from public.phase7_audit_log where event_type='request_approved' and entity_id=v_approve_two::text and actor_id=v_admin)<>1
    or (select count(distinct transaction_id) from public.phase7_audit_log where event_type='request_approved' and actor_id=v_admin and entity_id in (v_approve::text,v_approve_two::text))<>1 then
    raise exception 'Two same-transaction approvals must create one canonical row per borrowing.';
  end if;
  if position('entity_id' in pg_get_indexdef('public.phase7_audit_log_event_dedupe_idx'::regclass))=0 then
    raise exception 'Canonical event dedupe index must include entity_id.';
  end if;
  perform public.release_equipment_borrowing(v_approve,'good');
  perform public.complete_equipment_return(v_approve,'good');
  if (select count(*) from public.phase7_audit_log where entity_id=v_approve::text and actor_id=v_admin and event_type='equipment_released')<>1
    or (select count(*) from public.phase7_audit_log where entity_id=v_approve::text and actor_id=v_admin and event_type='equipment_returned')<>1 then
    raise exception 'Release and return must each produce one canonical event for an unlinked borrower.';
  end if;

  insert into public.borrowings(transaction_code,borrower_id,processed_by,purpose,destination,expected_return_date)
    values(v_code||'-D',v_unlinked,v_admin,'fixture','Room 1',now()+interval '5 days') returning borrowing_id into v_decline;
  insert into public.borrowing_items(borrowing_id,equipment_id,item_status,quantity) values(v_decline,v_equipment,'requested',1);
  perform public.review_borrowing_request(v_decline,'reject','Phase 7 decline');
  if (select count(*) from public.phase7_audit_log where event_type='request_declined' and entity_id=v_decline::text and actor_id=v_admin)<>1 then raise exception 'Decline must create one canonical event.'; end if;

  insert into public.feedback_threads(author_id,author_name,title,message) values(v_staff,'Private Name','P7 thread','Test') returning id into v_thread;
  insert into public.feedback_replies(thread_id,author_id,author_name,message) values(v_thread,v_admin,'Private Name','Private reply') returning id into v_reply;
  delete from public.feedback_replies where id=v_reply;
  if (select count(*) from public.phase7_audit_log where event_type='feedback_reply_deleted' and entity_id=v_reply::text and actor_id=v_admin and not (before_values ? 'message'))<>1 then raise exception 'Reply deletion must be logged once without reply text.'; end if;
  v_version:=public.publish_borrower_agreement('P7 agreement','Temporary test agreement.');
  if (select count(*) from public.phase7_audit_log where event_type='agreement_version_published' and entity_id=v_version::text and actor_id=v_admin)<>1 then raise exception 'Agreement publication must be logged once.'; end if;

  select count(*) into v_count from public.phase7_audit_log;
  v_result:=public.get_equipment_csv_template();
  if jsonb_array_length(v_result->'headers')=0 or (select count(*) from public.phase7_audit_log)<>v_count then
    raise exception 'Downloading the CSV template must not create an audit row.';
  end if;

  v_result:=public.import_equipment_csv(jsonb_build_array(
    jsonb_build_object('asset_code',v_code||'-bad','equipment_name','Rejected','category_name','missing','tracking_mode','quantity','quantity','1'),
    jsonb_build_object('asset_code','','equipment_name','Rejected','category_name','missing','tracking_mode','quantity','quantity','1')
  ),true);
  if (v_result->>'rows_rejected')::integer<>2 or (select count(*) from public.phase7_audit_log where event_type='csv_import_dry_run' and actor_id=v_admin and rows_rejected=2 and success=false)<>1 then raise exception 'Dry-run import audit must include rejected row count and failure state exactly once.'; end if;
  v_result:=public.import_equipment_csv(jsonb_build_array(jsonb_build_object('asset_code',v_code||'-import','equipment_name','Imported','category_name',(select category_name from public.categories where category_id=v_category),'tracking_mode','quantity','quantity','1')),false);
  if not (v_result->>'ok')::boolean or (select count(*) from public.phase7_audit_log where event_type='csv_import_succeeded' and actor_id=v_admin and row_count=1 and success)<>1 then raise exception 'Successful import must be logged exactly once.'; end if;

  perform public.admin_update_profile_access(v_staff,'property_custodian','inactive');
  if (select count(*) from public.phase7_audit_log where event_type='profile_access_changed' and entity_id=v_staff::text and actor_id=v_admin)<>1 then raise exception 'Admin profile-access RPC must audit the role and status update once.'; end if;
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  update public.profiles set role='staff',account_status='active' where id=v_staff;
  if (select count(*) from public.phase7_audit_log where event_type='profile_access_changed' and entity_id=v_staff::text and actor_id is null and source='direct_sql' and before_values->>'role'='property_custodian' and after_values->>'role'='staff' and before_values->>'account_status'='inactive' and after_values->>'account_status'='active')<>1 then raise exception 'Direct SQL role and account-status changes must be audited once with null actor and direct_sql source.'; end if;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin)::text,true);
  perform public.admin_update_profile_access(v_staff,'staff','active');

  insert into public.equipment(asset_code,equipment_name,category_id,quantity,availability_status)
    values(v_code||'-report','Phase 7 report fixture',v_category,2,'available') returning equipment_id into v_equipment;
  insert into public.borrowings(transaction_code,borrower_id,processed_by,purpose,destination,request_date,expected_return_date,transaction_status)
    values(v_code||'-r1',v_unlinked,v_admin,'report','Room 2',v_start,v_start+2,'returned') returning borrowing_id into v_approve;
  insert into public.borrowing_items(borrowing_id,equipment_id,item_status,quantity,issued_at,returned_at)
    values(v_approve,v_equipment,'returned',1,v_start,v_start+2) returning borrowing_item_id into v_item;
  insert into public.borrowings(transaction_code,borrower_id,processed_by,purpose,destination,request_date,expected_return_date,transaction_status)
    values(v_code||'-r2',v_unlinked,v_admin,'report','Room 2',v_start+1,v_start+3,'returned') returning borrowing_id into v_decline;
  insert into public.borrowing_items(borrowing_id,equipment_id,item_status,quantity,issued_at,returned_at)
    values(v_decline,v_equipment,'returned',1,v_start+1,v_start+3);
  insert into public.damage_loss_reports(borrowing_item_id,reporter_id,report_type,description)
    values(v_item,v_admin,'damage','fixture'),(v_item,v_admin,'loss','fixture');
  v_result:=public.get_phase7_report('utilization',v_start,v_end,0,false);
  if not exists(select 1 from jsonb_array_elements(v_result->'rows') r where r.value->>0=v_equipment::text and (r.value->>2)::integer=6 and (r.value->>4)::numeric=round(6::numeric/(2*(v_end-v_start+1)),4)) then raise exception 'Utilization fixture total is incorrect.'; end if;
  v_result:=public.get_phase7_report('most_borrowed',v_start,v_end,0,false);
  if not exists(select 1 from jsonb_array_elements(v_result->'rows') r where r.value->>0=v_equipment::text and (r.value->>2)::integer=2) then raise exception 'Most-borrowed fixture total is incorrect.'; end if;
  v_result:=public.get_phase7_report('damage_loss',v_start,v_end,0,false);
  if not exists(select 1 from jsonb_array_elements(v_result->'rows') r where r.value->>0=v_equipment::text and (r.value->>3)::integer=1 and (r.value->>4)::integer=1) then raise exception 'Damage/loss fixture totals are incorrect.'; end if;
  v_result:=public.get_phase7_report('utilization',v_start,v_end,0,true);
  if (select count(*) from public.phase7_audit_log where event_type='report_exported' and entity_id='utilization' and actor_id=v_admin and filters->>'start_date'=v_start::text and row_count=jsonb_array_length(v_result->'rows'))<>1 then raise exception 'Report export audit must include actor, filters, and returned row count exactly once.'; end if;
  v_result:=public.get_phase7_audit_history(0,v_start,v_end,null,null,null,true);
  if (select count(*) from public.phase7_audit_log where event_type='audit_log_exported' and actor_id=v_admin and row_count=jsonb_array_length(v_result->'rows'))<>1 then raise exception 'Audit export must log its actor, filters, and returned row count exactly once.'; end if;
  insert into public.borrowings(transaction_code,borrower_id,processed_by,purpose,destination,request_date,expected_return_date,transaction_status)
    values(v_code||'-overdue',v_unlinked,v_admin,'overdue','Room 3',current_date-10,current_date-3,'released') returning borrowing_id into v_approve;
  insert into public.borrowing_items(borrowing_id,equipment_id,item_status,quantity,is_overdue,overdue_at) values(v_approve,v_equipment,'released',1,true,now());
  v_result:=public.get_phase7_report('overdue',v_start,v_end,0,false);
  if not exists(select 1 from jsonb_array_elements(v_result->'rows') r where r.value->>1='Unlinked Borrower' and (r.value->>3)::integer=1 and (r.value->>4)::integer=3) then raise exception 'Overdue fixture total is incorrect.'; end if;
  begin
    perform public.get_phase7_report('utilization',v_start-366,v_end,0,false);
    raise exception 'Report range above 366 days was accepted.';
  exception when raise_exception then
    if sqlerrm='Report range above 366 days was accepted.' then raise; end if;
    if sqlerrm not like '%366 days or fewer%' then raise; end if;
  end;
end;
$$;

do $$
declare v_admin uuid; v_staff uuid; v_custodian uuid; v_result jsonb; v_table text; v_set text; v_trigger text; v_report_type text;
  v_equipment bigint; v_unit bigint; v_asset_tag text; v_expected_back timestamptz;
  v_maintenance_id bigint;
begin
  select id into v_admin from public.profiles where role='admin' and account_status='active' order by created_at limit 1;
  select id into v_staff from public.profiles where role='staff' and account_status='active' order by created_at limit 1;
  select id into v_custodian from public.profiles where role='property_custodian' and account_status='active' order by created_at limit 1;
  perform set_config('request.jwt.claim.sub',v_staff::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_staff)::text,true);
  begin perform public.get_phase7_audit_history(0,null,null,null,null,null,false); raise exception 'Non-admin read audit unexpectedly succeeded.';
  exception when others then if sqlerrm='Non-admin read audit unexpectedly succeeded.' then raise; end if; if sqlerrm not like '%Only administrators and property custodians%' then raise; end if; end;
  foreach v_report_type in array array['utilization','most_borrowed','overdue','damage_loss'] loop
    begin perform public.get_phase7_report(v_report_type,current_date-1,current_date,0,false); raise exception 'Non-admin report unexpectedly succeeded.';
    exception when others then if sqlerrm='Non-admin report unexpectedly succeeded.' then raise; end if; if sqlerrm not like '%Only administrators and property custodians%' then raise; end if; end;
    begin perform public.get_phase7_report(v_report_type,current_date-1,current_date,0,true); raise exception 'Non-admin export unexpectedly succeeded.';
    exception when others then if sqlerrm='Non-admin export unexpectedly succeeded.' then raise; end if; if sqlerrm not like '%Only administrators and property custodians%' then raise; end if; end;
  end loop;
  begin perform public.get_phase7_audit_history(0,null,null,null,null,null,true); raise exception 'Non-admin audit export unexpectedly succeeded.';
  exception when others then if sqlerrm='Non-admin audit export unexpectedly succeeded.' then raise; end if; if sqlerrm not like '%Only administrators and property custodians%' then raise; end if; end;
  perform set_config('request.jwt.claim.sub',v_custodian::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_custodian)::text,true);
  v_result:=public.get_phase7_audit_history(0,null,null,null,'profile_access_changed',null,false);
  if (v_result->>'total_count')::integer<>0 then raise exception 'Custodian history exposed a role change.'; end if;
  v_result:=public.get_phase7_audit_history(0,null,null,null,'request_approved',null,false);
  if (v_result->>'total_count')::integer=0 then raise exception 'Custodian cannot read borrowing events.'; end if;

  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin)::text,true);
  insert into public.account_access_audit_log(account_id,actor_id,decision,before_values,after_values)
    values(v_staff,v_admin,'approved','{"account_status":"pending"}'::jsonb,'{"account_status":"active"}'::jsonb);
  insert into public.equipment(asset_code,equipment_name,category_id,quantity,tracking_mode,availability_status)
    values('P7-IMMUTABLE-'||replace(gen_random_uuid()::text,'-',''),'Immutable fixture',
      (select category_id from public.categories order by category_id limit 1),1,'unit','available') returning equipment_id into v_equipment;
  v_asset_tag:='P7-IMMUTABLE-'||replace(gen_random_uuid()::text,'-','');
  insert into public.equipment_units(equipment_id,asset_tag,status,calibration_due_at)
    values(v_equipment,v_asset_tag,'available',current_date) returning unit_id into v_unit;
  insert into public.equipment_unit_audit(unit_id,equipment_id,actor_id,action,new_values)
    values(v_unit,v_equipment,v_admin,'insert','{"status":"available"}'::jsonb);
  insert into public.unit_maintenance_log(unit_id,reason,started_at,completed_at,recorded_by,closes_maintenance_id)
    values(v_unit,'Old-style completed maintenance',now()-interval '2 days',now()-interval '1 day',v_admin,null)
    returning maintenance_id into v_maintenance_id;
  if public.phase7_unit_maintenance_is_open(v_maintenance_id) then
    raise exception 'An old-style completed maintenance row must not be open.';
  end if;
  select expected_back_at into v_expected_back
  from public.search_equipment_units_page(v_asset_tag,null,0) where unit_id=v_unit;
  if v_expected_back is not null then raise exception 'The maintenance list treated an old completed row as open.'; end if;
  if not exists(select 1 from public.equipment_units_due_for_calibration(0) where unit_id=v_unit) then
    raise exception 'The calibration due list treated an old completed row as active maintenance.';
  end if;
  v_result:=public.get_phase7_audit_history(0,null,null,null,null,null,true);
  if not exists(select 1 from jsonb_array_elements(v_result->'rows') r
    where r.value->>'source_table'='unit_maintenance_log'
      and r.value->>'entity_id'=v_maintenance_id::text
      and r.value->>'event_type'='maintenance_completed') then
    raise exception 'The old-style completed maintenance row must appear in audit history.';
  end if;
  foreach v_table in array array['phase7_audit_log','equipment_audit_log','borrowing_workflow_audit','account_access_audit_log','borrower_agreement_audit_log','equipment_unit_audit','equipment_import_audit','unit_maintenance_log'] loop
    if not exists(select 1 from jsonb_array_elements(v_result->'rows') r where r.value->>'source_table'=v_table) then raise exception 'Audit history union is missing %.',v_table; end if;
  end loop;
  if has_table_privilege('authenticated','public.phase7_audit_log','SELECT') or has_table_privilege('authenticated','public.equipment_audit_log','SELECT') then raise exception 'Audit reads must be RPC-only.'; end if;

  foreach v_table in array array['phase7_audit_log','equipment_audit_log','borrowing_workflow_audit','account_access_audit_log','borrower_agreement_audit_log','equipment_unit_audit','equipment_import_audit','unit_maintenance_log'] loop
    if has_table_privilege('authenticated','public.'||v_table,'INSERT') or has_table_privilege('authenticated','public.'||v_table,'UPDATE') or has_table_privilege('authenticated','public.'||v_table,'DELETE')
      or has_table_privilege('anon','public.'||v_table,'INSERT') or has_table_privilege('anon','public.'||v_table,'UPDATE') or has_table_privilege('anon','public.'||v_table,'DELETE') then raise exception 'API writes remain granted on %.',v_table; end if;
    v_set:=case v_table when 'phase7_audit_log' then 'event_type=event_type' when 'equipment_audit_log' then 'action=action'
      when 'borrowing_workflow_audit' then 'event_type=event_type' when 'account_access_audit_log' then 'decision=decision'
      when 'borrower_agreement_audit_log' then 'action=action' when 'equipment_unit_audit' then 'action=action'
      when 'equipment_import_audit' then 'row_count=row_count' else 'reason=reason' end;
    v_trigger:=case v_table when 'phase7_audit_log' then 'phase7_canonical_immutable' when 'equipment_audit_log' then 'phase7_equipment_immutable'
      when 'borrowing_workflow_audit' then 'phase7_borrowing_immutable' when 'account_access_audit_log' then 'phase7_account_immutable'
      when 'borrower_agreement_audit_log' then 'phase7_agreement_immutable' when 'equipment_unit_audit' then 'phase7_unit_immutable'
      when 'equipment_import_audit' then 'phase7_import_immutable' else 'phase7_maintenance_immutable' end;
    if not exists(select 1 from pg_trigger where tgrelid=('public.'||v_table)::regclass and tgname=v_trigger and not tgisinternal) then raise exception 'Missing append-only trigger on %.',v_table; end if;
    begin execute format('update public.%I set %s where ctid=(select ctid from public.%I limit 1)',v_table,v_set,v_table); raise exception 'Phase 7 update unexpectedly succeeded.';
    exception when others then if sqlerrm='Phase 7 update unexpectedly succeeded.' then raise; end if; end;
    begin execute format('delete from public.%I where ctid=(select ctid from public.%I limit 1)',v_table,v_table); raise exception 'Phase 7 delete unexpectedly succeeded.';
    exception when others then if sqlerrm='Phase 7 delete unexpectedly succeeded.' then raise; end if; end;
  end loop;

  if public.sanitize_csv_cell('=1+1')<>'''=1+1' or public.sanitize_csv_cell('+cmd')<>'''+cmd'
    or public.sanitize_csv_cell('-1')<>'''-1' or public.sanitize_csv_cell('@SUM(A1)')<>'''@SUM(A1)'
    or public.sanitize_csv_cell(E'\t=1')<>E'''\t=1' or public.sanitize_csv_cell(' =1')<>''' =1'
    or public.sanitize_csv_cell('normal')<>'normal' then raise exception 'CSV sanitizer fixture failed.'; end if;
  if public.quote_csv_cell('a,b')<>'"a,b"' or public.quote_csv_cell('a"b')<>'"a""b"' or public.quote_csv_cell(E'a\nb')<>E'"a\nb"' then raise exception 'CSV quoting fixture failed.'; end if;
end;
$$;

set constraints all immediate;
rollback;