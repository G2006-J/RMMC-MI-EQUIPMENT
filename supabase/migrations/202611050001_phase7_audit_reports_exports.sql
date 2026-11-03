begin;

create table public.phase7_audit_log (
  audit_id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id) on delete set null,
  source text not null check (source in ('trigger', 'rpc', 'direct_sql')),
  event_type text not null,
  entity_type text not null,
  entity_id text,
  before_values jsonb,
  after_values jsonb,
  filters jsonb,
  row_count integer,
  success boolean,
  rows_rejected integer,
  transaction_id bigint,
  created_at timestamptz not null default now()
);
create index phase7_audit_log_created_idx on public.phase7_audit_log (created_at desc, audit_id desc);
create index phase7_audit_log_actor_event_idx on public.phase7_audit_log (actor_id, event_type, created_at desc);
create unique index phase7_audit_log_event_dedupe_idx
  on public.phase7_audit_log (transaction_id, event_type, entity_type, entity_id);
alter table public.phase7_audit_log enable row level security;
revoke all on public.phase7_audit_log from public, anon, authenticated;

alter table public.equipment_audit_log enable row level security;
alter table public.borrowing_workflow_audit enable row level security;
alter table public.account_access_audit_log enable row level security;
alter table public.borrower_agreement_audit_log enable row level security;
alter table public.equipment_unit_audit enable row level security;
alter table public.equipment_import_audit enable row level security;
alter table public.unit_maintenance_log enable row level security;
revoke insert, update, delete on public.equipment_audit_log, public.borrowing_workflow_audit,
  public.account_access_audit_log, public.borrower_agreement_audit_log,
  public.equipment_unit_audit, public.equipment_import_audit, public.unit_maintenance_log
  from public, anon, authenticated;
revoke select on public.equipment_audit_log, public.borrowing_workflow_audit,
  public.account_access_audit_log, public.borrower_agreement_audit_log,
  public.equipment_unit_audit, public.equipment_import_audit, public.unit_maintenance_log
  from public, anon, authenticated;

create or replace function public.phase7_block_equipment_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then raise exception 'Audit history is append-only.'; end if;
  raise exception 'Audit history is append-only.';
end; $$;
create or replace function public.phase7_block_borrowing_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then raise exception 'Audit history is append-only.'; end if;
  raise exception 'Audit history is append-only.';
end; $$;
create or replace function public.phase7_block_account_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then raise exception 'Audit history is append-only.'; end if;
  raise exception 'Audit history is append-only.';
end; $$;
create or replace function public.phase7_block_agreement_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then raise exception 'Audit history is append-only.'; end if;
  raise exception 'Audit history is append-only.';
end; $$;
create or replace function public.phase7_block_unit_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then raise exception 'Audit history is append-only.'; end if;
  raise exception 'Audit history is append-only.';
end; $$;
create or replace function public.phase7_block_import_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then raise exception 'Audit history is append-only.'; end if;
  raise exception 'Audit history is append-only.';
end; $$;
create or replace function public.phase7_block_canonical_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then raise exception 'Audit history is append-only.'; end if;
  raise exception 'Audit history is append-only.';
end; $$;
create or replace function public.phase7_block_maintenance_log()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then raise exception 'Maintenance history is append-only.'; end if;
  raise exception 'Maintenance history is append-only.';
end; $$;

revoke all on function public.phase7_block_equipment_audit() from public, anon, authenticated;
revoke all on function public.phase7_block_borrowing_audit() from public, anon, authenticated;
revoke all on function public.phase7_block_account_audit() from public, anon, authenticated;
revoke all on function public.phase7_block_agreement_audit() from public, anon, authenticated;
revoke all on function public.phase7_block_unit_audit() from public, anon, authenticated;
revoke all on function public.phase7_block_import_audit() from public, anon, authenticated;
revoke all on function public.phase7_block_canonical_audit() from public, anon, authenticated;
revoke all on function public.phase7_block_maintenance_log() from public, anon, authenticated;
create trigger phase7_equipment_immutable before update or delete on public.equipment_audit_log for each row execute function public.phase7_block_equipment_audit();
create trigger phase7_borrowing_immutable before update or delete on public.borrowing_workflow_audit for each row execute function public.phase7_block_borrowing_audit();
create trigger phase7_account_immutable before update or delete on public.account_access_audit_log for each row execute function public.phase7_block_account_audit();
create trigger phase7_agreement_immutable before update or delete on public.borrower_agreement_audit_log for each row execute function public.phase7_block_agreement_audit();
create trigger phase7_unit_immutable before update or delete on public.equipment_unit_audit for each row execute function public.phase7_block_unit_audit();
create trigger phase7_import_immutable before update or delete on public.equipment_import_audit for each row execute function public.phase7_block_import_audit();
create trigger phase7_canonical_immutable before update or delete on public.phase7_audit_log for each row execute function public.phase7_block_canonical_audit();
create trigger phase7_maintenance_immutable before update or delete on public.unit_maintenance_log for each row execute function public.phase7_block_maintenance_log();

alter table public.unit_maintenance_log
  add column closes_maintenance_id bigint references public.unit_maintenance_log(maintenance_id) on delete restrict;
drop index if exists public.unit_maintenance_one_open_idx;
create index unit_maintenance_open_lookup_idx on public.unit_maintenance_log (unit_id, maintenance_id desc)
  where completed_at is null and closes_maintenance_id is null;

create or replace function public.phase7_unit_maintenance_is_open(p_maintenance_id bigint)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_actor uuid := (select auth.uid());
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only equipment managers can inspect maintenance history.';
  end if;
  return exists (
    select 1
    from public.unit_maintenance_log m
    where m.maintenance_id = p_maintenance_id
      and m.completed_at is null
      and m.closes_maintenance_id is null
      and not exists (
        select 1 from public.unit_maintenance_log c
        where c.closes_maintenance_id = m.maintenance_id
      )
  );
end; $$;
revoke all on function public.phase7_unit_maintenance_is_open(bigint) from public, anon;
grant execute on function public.phase7_unit_maintenance_is_open(bigint) to authenticated;

create or replace function public.equipment_units_due_for_calibration(p_days integer default 14)
returns table (unit_id bigint, equipment_id bigint, asset_tag text, calibration_due_at date, status text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can view calibration dates.';
  end if;
  if p_days < 0 or p_days > 365 then raise exception 'Choose a due window from 0 to 365 days.'; end if;
  return query
  select u.unit_id, u.equipment_id, u.asset_tag, u.calibration_due_at, u.status
  from public.equipment_units u
  where u.status <> 'retired'
    and u.calibration_due_at between current_date and current_date + p_days
    and not exists (
      select 1 from public.unit_maintenance_log m
      where m.unit_id = u.unit_id
        and public.phase7_unit_maintenance_is_open(m.maintenance_id)
    )
  order by u.calibration_due_at, u.unit_id;
end; $$;
revoke all on function public.equipment_units_due_for_calibration(integer) from public, anon;
grant execute on function public.equipment_units_due_for_calibration(integer) to authenticated;

create or replace function public.search_equipment_units_page(
  p_search text default null, p_status text default null, p_after_unit_id bigint default 0
)
returns table (unit_id bigint, equipment_id bigint, equipment_name text, asset_tag text,
  serial_number text, status text, notes text, calibration_due_at date, expected_back_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then raise exception 'Only equipment managers can search units.'; end if;
  return query
  select u.unit_id, u.equipment_id, e.equipment_name::text, u.asset_tag, u.serial_number,
    u.status, u.notes, u.calibration_due_at, m.expected_back_at
  from public.equipment_units u join public.equipment e using (equipment_id)
  left join lateral (
    select open_row.expected_back_at from public.unit_maintenance_log open_row
    where open_row.unit_id = u.unit_id
      and public.phase7_unit_maintenance_is_open(open_row.maintenance_id)
    order by open_row.maintenance_id desc limit 1
  ) m on true
  where u.unit_id > coalesce(p_after_unit_id, 0) and (p_status is null or u.status = p_status)
    and (nullif(trim(p_search), '') is null or lower(u.asset_tag) like lower(trim(p_search)) || '%'
      or lower(coalesce(u.serial_number, '')) like lower(trim(p_search)) || '%'
      or lower(e.equipment_name) like lower(trim(p_search)) || '%')
  order by u.unit_id limit 20;
end; $$;
revoke all on function public.search_equipment_units_page(text, text, bigint) from public, anon;
grant execute on function public.search_equipment_units_page(text, text, bigint) to authenticated;

create or replace function public.set_equipment_unit_status(
  p_unit_id bigint, p_status text, p_reason text default null,
  p_started_at timestamptz default now(), p_expected_back_at timestamptz default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := (select auth.uid()); v_equipment_id bigint; v_old_status text;
  v_open public.unit_maintenance_log%rowtype;
begin
  if v_actor is null or not public.is_equipment_manager_user() then raise exception 'Only equipment managers can change unit status.'; end if;
  if p_status not in ('available', 'maintenance', 'retired') then raise exception 'Use release and return workflows for borrowed or lost units.'; end if;
  select equipment_id into v_equipment_id from public.equipment_units where unit_id = p_unit_id;
  if not found then raise exception 'Equipment unit not found.'; end if;
  perform 1 from public.equipment where equipment_id = v_equipment_id for update;
  select status into v_old_status from public.equipment_units where unit_id = p_unit_id for update;
  if v_old_status in ('borrowed', 'lost', 'retired') then raise exception 'Borrowed or lost units cannot be changed through maintenance controls.'; end if;
  if v_old_status = p_status then raise exception 'The unit is already in that status.'; end if;
  if p_status = 'maintenance' and nullif(trim(p_reason), '') is null then raise exception 'A reason is required to place a unit in maintenance.'; end if;
  update public.equipment_units set status = p_status, updated_at = now() where unit_id = p_unit_id;
  if p_status = 'maintenance' then
    update public.equipment set out_of_service_quantity = out_of_service_quantity + 1, updated_at = now() where equipment_id = v_equipment_id;
    insert into public.unit_maintenance_log (unit_id, reason, started_at, expected_back_at, recorded_by)
      values (p_unit_id, trim(p_reason), coalesce(p_started_at, now()), p_expected_back_at, v_actor);
  elsif v_old_status = 'maintenance' then
    select m.* into v_open from public.unit_maintenance_log m
    where m.unit_id = p_unit_id
      and public.phase7_unit_maintenance_is_open(m.maintenance_id)
    order by m.maintenance_id desc limit 1;
    if found then
      insert into public.unit_maintenance_log (unit_id, reason, started_at, expected_back_at, completed_at, recorded_by, closes_maintenance_id)
        values (p_unit_id, 'Maintenance completed', v_open.started_at, v_open.expected_back_at, now(), v_actor, v_open.maintenance_id);
      update public.equipment set out_of_service_quantity = out_of_service_quantity - 1, updated_at = now() where equipment_id = v_equipment_id;
    end if;
  end if;
  if p_status = 'retired' then update public.equipment set quantity = quantity - 1, updated_at = now() where equipment_id = v_equipment_id; end if;
  update public.equipment e set availability_status = case
    when e.availability_status = 'retired' then 'retired'
    when e.tracking_mode = 'unit' and e.quantity = 0 then 'retired'
    when e.tracking_mode = 'unit' and not exists (select 1 from public.equipment_units u where u.equipment_id=e.equipment_id and u.status='available') then
      case
        when exists (select 1 from public.equipment_units u where u.equipment_id=e.equipment_id and u.status='borrowed') then 'borrowed'
        when exists (
          select 1 from public.equipment_units u
          join public.unit_maintenance_log m on m.unit_id = u.unit_id
          where u.equipment_id=e.equipment_id and u.status='maintenance'
            and public.phase7_unit_maintenance_is_open(m.maintenance_id)
        ) then 'maintenance'
        else 'maintenance'
      end
    when e.quantity-e.out_of_service_quantity <= 0 then 'maintenance' else 'available' end, updated_at=now()
  where e.equipment_id=v_equipment_id;
  insert into public.equipment_unit_audit (unit_id,equipment_id,actor_id,action,old_values,new_values)
  values (p_unit_id,v_equipment_id,v_actor,case when p_status='retired' then 'retired' else 'status_changed' end,
    jsonb_build_object('status',v_old_status),jsonb_build_object('status',p_status,'reason',nullif(trim(p_reason),''),'expected_back_at',p_expected_back_at));
end; $$;
revoke all on function public.set_equipment_unit_status(bigint,text,text,timestamptz,timestamptz) from public, anon;
grant execute on function public.set_equipment_unit_status(bigint,text,text,timestamptz,timestamptz) to authenticated;

create or replace function public.phase7_log_borrowing_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := (select auth.uid()); v_role text; v_event text;
begin
  if new.transaction_status is not distinct from old.transaction_status then return new; end if;
  if v_actor is not null then
    select p.role into v_role from public.profiles p where p.id=v_actor and p.account_status='active';
    if v_role not in ('admin','property_custodian','staff') then raise exception 'An active caller profile is required.'; end if;
  elsif session_user not in ('postgres','supabase_admin') then raise exception 'A verified actor is required.'; end if;
  v_event := case when old.transaction_status='requested' and new.transaction_status='approved' then 'request_approved'
    when old.transaction_status='requested' and new.transaction_status='rejected' then 'request_declined'
    when old.transaction_status='approved' and new.transaction_status='released' then 'equipment_released'
    when old.transaction_status='released' and new.transaction_status='returned' then 'equipment_returned'
    else 'borrowing_status_changed' end;
  begin
    insert into public.phase7_audit_log(actor_id,source,event_type,entity_type,entity_id,before_values,after_values,transaction_id)
    values(v_actor,case when v_actor is null then 'direct_sql' else 'trigger' end,v_event,'borrowing',new.borrowing_id::text,
      jsonb_build_object('status',old.transaction_status),jsonb_build_object('status',new.transaction_status),txid_current())
    on conflict (transaction_id,event_type,entity_type,entity_id) do nothing;
  exception when check_violation or foreign_key_violation or not_null_violation or unique_violation or insufficient_privilege or data_exception then
    raise warning 'Borrowing audit insert failed for borrowing %.',new.borrowing_id;
  end;
  return new;
end; $$;
create or replace function public.phase7_log_borrowing_item_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := (select auth.uid()); v_role text; v_event text;
begin
  if new.item_status is not distinct from old.item_status and new.is_overdue is not distinct from old.is_overdue then return new; end if;
  if v_actor is not null then
    select p.role into v_role from public.profiles p where p.id=v_actor and p.account_status='active';
    if v_role not in ('admin','property_custodian','staff') then raise exception 'An active caller profile is required.'; end if;
  elsif session_user not in ('postgres','supabase_admin') then raise exception 'A verified actor is required.'; end if;
  v_event := case when old.item_status='requested' and new.item_status='approved' then 'request_approved'
    when old.item_status='requested' and new.item_status='rejected' then 'request_declined'
    when old.item_status='approved' and new.item_status='released' then 'equipment_released'
    when old.item_status='released' and new.item_status='returned' then 'equipment_returned'
    when new.is_overdue is distinct from old.is_overdue then 'overdue_flagged' else 'borrowing_item_status_changed' end;
  begin
    insert into public.phase7_audit_log(actor_id,source,event_type,entity_type,entity_id,before_values,after_values,transaction_id)
    values(v_actor,case when v_actor is null then 'direct_sql' else 'trigger' end,v_event,'borrowing',new.borrowing_id::text,
      jsonb_build_object('item_status',old.item_status,'is_overdue',old.is_overdue),
      jsonb_build_object('item_status',new.item_status,'is_overdue',new.is_overdue),txid_current())
    on conflict (transaction_id,event_type,entity_type,entity_id) do nothing;
  exception when check_violation or foreign_key_violation or not_null_violation or unique_violation or insufficient_privilege or data_exception then
    raise warning 'Borrowing item audit insert failed for borrowing %.',new.borrowing_id;
  end;
  return new;
end; $$;
revoke all on function public.phase7_log_borrowing_change() from public, anon, authenticated;
revoke all on function public.phase7_log_borrowing_item_change() from public, anon, authenticated;
create trigger phase7_borrowing_events after update of transaction_status on public.borrowings for each row execute function public.phase7_log_borrowing_change();
create trigger phase7_borrowing_item_events after update of item_status,is_overdue on public.borrowing_items for each row execute function public.phase7_log_borrowing_item_change();

create or replace function public.phase7_audit_profile_access_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := (select auth.uid()); v_role text; v_fields text[] := '{}'::text[]; v_before jsonb := '{}'::jsonb; v_after jsonb := '{}'::jsonb;
begin
  if new.role is distinct from old.role then v_fields:=array_append(v_fields,'role'); v_before:=v_before||jsonb_build_object('role',old.role); v_after:=v_after||jsonb_build_object('role',new.role); end if;
  if new.account_status is distinct from old.account_status then v_fields:=array_append(v_fields,'account_status'); v_before:=v_before||jsonb_build_object('account_status',old.account_status); v_after:=v_after||jsonb_build_object('account_status',new.account_status); end if;
  if cardinality(v_fields)=0 then return new; end if;
  if v_actor is not null then select p.role into v_role from public.profiles p where p.id=v_actor; end if;
  begin
    insert into public.phase7_audit_log(actor_id,source,event_type,entity_type,entity_id,before_values,after_values)
    values(v_actor,case when v_actor is null then 'direct_sql' else 'trigger' end,'profile_access_changed','profile',new.id::text,
      jsonb_build_object('changed_fields',to_jsonb(v_fields))||v_before,jsonb_build_object('changed_fields',to_jsonb(v_fields))||v_after);
  exception when check_violation or foreign_key_violation or not_null_violation or unique_violation or insufficient_privilege then
    raise warning 'Profile access audit insert failed for profile %.',new.id;
  end;
  return new;
end; $$;
revoke all on function public.phase7_audit_profile_access_change() from public, anon, authenticated;
create trigger phase7_profile_access_audit after update of role,account_status on public.profiles for each row execute function public.phase7_audit_profile_access_change();

create or replace function public.admin_update_profile_access(p_user_id uuid,p_role text,p_account_status text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := (select auth.uid());
begin
  if v_actor is null or not public.is_equipment_admin_user() or not exists(select 1 from public.profiles p where p.id=v_actor and p.role='admin' and p.account_status='active') then raise exception 'Only an active administrator can change profile access.'; end if;
  if p_role not in ('admin','property_custodian','staff') or p_account_status not in ('pending','active','inactive') then raise exception 'Choose a valid role and account status.'; end if;
  update public.profiles set role=p_role,account_status=p_account_status,updated_at=now() where id=p_user_id;
  if not found then raise exception 'Profile not found.'; end if;
  update public.borrowers set status=p_account_status where user_id=p_user_id;
end; $$;
revoke all on function public.admin_update_profile_access(uuid,text,text) from public, anon;
grant execute on function public.admin_update_profile_access(uuid,text,text) to authenticated;

create or replace function public.phase7_audit_feedback_reply_delete()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := (select auth.uid());
begin
  if v_actor is not null and not public.is_equipment_admin_user() then raise exception 'Only administrators can delete feedback replies.'; end if;
  begin
    insert into public.phase7_audit_log(actor_id,source,event_type,entity_type,entity_id,before_values,after_values)
    values(v_actor,case when v_actor is null then 'direct_sql' else 'trigger' end,'feedback_reply_deleted','feedback_reply',old.id::text,
      jsonb_build_object('changed_fields',jsonb_build_array('deleted'),'thread_id',old.thread_id),jsonb_build_object('changed_fields',jsonb_build_array('deleted')));
  exception when check_violation or foreign_key_violation or not_null_violation or unique_violation or insufficient_privilege then
    raise warning 'Feedback reply audit insert failed for reply %.',old.id;
  end;
  return old;
end; $$;
revoke all on function public.phase7_audit_feedback_reply_delete() from public, anon, authenticated;
create trigger phase7_feedback_reply_deleted after delete on public.feedback_replies for each row execute function public.phase7_audit_feedback_reply_delete();

create or replace function public.phase7_audit_agreement_publish()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := coalesce(new.published_by,(select auth.uid()));
begin
  if v_actor is not null and not exists(select 1 from public.profiles p where p.id=v_actor and p.role='admin' and p.account_status='active') then raise exception 'Only an active administrator can publish an agreement.'; end if;
  begin
    insert into public.phase7_audit_log(actor_id,source,event_type,entity_type,entity_id,before_values,after_values)
    values(v_actor,case when (select auth.uid()) is null then 'direct_sql' else 'trigger' end,'agreement_version_published','borrower_agreement_version',new.version_id::text,
      (select jsonb_build_object('version_id',v.version_id,'version_number',v.version_number) from public.borrower_agreement_versions v where v.version_number<new.version_number order by v.version_number desc limit 1),
      jsonb_build_object('version_id',new.version_id,'version_number',new.version_number,'changed_fields',jsonb_build_array('version_number','title','body_text')));
  exception when check_violation or foreign_key_violation or not_null_violation or unique_violation or insufficient_privilege then
    raise warning 'Agreement audit insert failed for version %.',new.version_id;
  end;
  return new;
end; $$;
revoke all on function public.phase7_audit_agreement_publish() from public, anon, authenticated;
create trigger phase7_agreement_published after insert on public.borrower_agreement_versions for each row execute function public.phase7_audit_agreement_publish();

alter function public.import_equipment_csv(jsonb,boolean) rename to import_equipment_csv_internal;
revoke all on function public.import_equipment_csv_internal(jsonb,boolean) from public, anon, authenticated;
create function public.import_equipment_csv(p_rows jsonb,p_dry_run boolean default true)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=(select auth.uid()); v_result jsonb; v_success boolean:=false; v_rejected integer:=0; v_rows integer:=coalesce(jsonb_array_length(p_rows),0);
begin
  if v_actor is null or not public.is_equipment_admin_user() then raise exception 'Only administrators can import equipment.'; end if;
  begin
    v_result:=public.import_equipment_csv_internal(p_rows,p_dry_run);
    v_success:=coalesce((v_result->>'ok')::boolean,false);
    select count(*)::integer into v_rejected from jsonb_array_elements(coalesce(v_result->'rows','[]'::jsonb)) r where coalesce((r.value->>'valid')::boolean,false)=false;
  exception when raise_exception or data_exception or integrity_constraint_violation or invalid_parameter_value then
    v_result:=jsonb_build_object('ok',false,'error',sqlerrm,'rows','[]'::jsonb); v_success:=false; v_rejected:=v_rows;
  end;
  begin
    insert into public.phase7_audit_log(actor_id,source,event_type,entity_type,filters,row_count,success,rows_rejected)
    values(v_actor,'rpc',case when p_dry_run then 'csv_import_dry_run' when v_success then 'csv_import_succeeded' else 'csv_import_failed' end,
      'equipment_import',jsonb_build_object('dry_run',p_dry_run,'rows_submitted',v_rows),v_rows,v_success,v_rejected);
  exception when check_violation or foreign_key_violation or not_null_violation or unique_violation or insufficient_privilege or data_exception then
    raise warning 'CSV import audit insert failed for actor %.',v_actor;
  end;
  return v_result||jsonb_build_object('rows_rejected',v_rejected);
end; $$;
revoke all on function public.import_equipment_csv(jsonb,boolean) from public, anon;
grant execute on function public.import_equipment_csv(jsonb,boolean) to authenticated;

create or replace function public.get_equipment_csv_template()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_actor uuid := (select auth.uid());
begin
  if v_actor is null or not public.is_equipment_manager_user() then raise exception 'Only equipment managers can download the import template.'; end if;
  return jsonb_build_object(
    'headers',jsonb_build_array('asset_code','equipment_name','category_name','tracking_mode','quantity','unit_asset_tag','serial_number','unit_status','notes','calibration_due_at'),
    'rows',jsonb_build_array(jsonb_build_array('CAM-001','Canon camera','General','unit',2,'CAM-001-A','SERIAL-001','available','',''))
  );
end; $$;
revoke all on function public.get_equipment_csv_template() from public, anon;
grant execute on function public.get_equipment_csv_template() to authenticated;

create or replace function public.sanitize_csv_cell(p_value text)
returns text language sql immutable set search_path = '' as $$
  select case when substring(ltrim(coalesce(p_value,''),' ') from 1 for 1) in ('=','+','-','@',chr(9),chr(13))
    then ''''||coalesce(p_value,'') else coalesce(p_value,'') end;
$$;
create or replace function public.quote_csv_cell(p_value text)
returns text language sql immutable set search_path = '' as $$
  select '"'||replace(public.sanitize_csv_cell(coalesce(p_value,'')),'"','""')||'"';
$$;
revoke all on function public.sanitize_csv_cell(text) from public, anon, authenticated;
revoke all on function public.quote_csv_cell(text) from public, anon, authenticated;

create or replace function public.get_phase7_audit_history(
  p_page integer default 0,p_start_date date default null,p_end_date date default null,
  p_actor uuid default null,p_event_type text default null,p_search text default null,p_export boolean default false
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=(select auth.uid()); v_admin boolean; v_rows jsonb; v_total integer;
begin
  if v_actor is null or not public.is_equipment_manager_user() then raise exception 'Only administrators and property custodians can read audit history.'; end if;
  select p.role='admin' into v_admin from public.profiles p where p.id=v_actor and p.account_status='active';
  if p_page is null or p_page<0 or (p_start_date is not null and p_end_date is not null and p_end_date<p_start_date) then raise exception 'Choose a valid audit date range and page.'; end if;
  with history as (
    select a.created_at event_time,a.actor_id,a.event_type,a.entity_type,a.entity_id,a.before_values,a.after_values,a.source,'phase7_audit_log'::text source_table from public.phase7_audit_log a
    union all select a.changed_at,a.actor_id,'equipment_'||a.action,'equipment',a.equipment_id::text,a.old_values,a.new_values,'legacy','equipment_audit_log' from public.equipment_audit_log a
    union all select a.changed_at,a.actor_id,a.event_type,a.entity_type,coalesce(a.borrowing_item_id::text,a.damage_report_id::text,a.borrowing_id::text),a.before_values,a.after_values,'legacy','borrowing_workflow_audit' from public.borrowing_workflow_audit a
    union all select a.changed_at,a.actor_id,'account_'||a.decision,'profile',a.account_id::text,a.before_values,a.after_values,'legacy','account_access_audit_log' from public.account_access_audit_log a
    union all select a.changed_at,a.actor_id,'agreement_'||a.action,'borrower_agreement_version',a.version_id::text,a.before_values-'body_text',a.after_values-'body_text','legacy','borrower_agreement_audit_log' from public.borrower_agreement_audit_log a
    union all select a.changed_at,a.actor_id,'equipment_unit_'||a.action,'equipment_unit',a.unit_id::text,jsonb_build_object('status',a.old_values->'status'),jsonb_build_object('status',a.new_values->'status'),'legacy','equipment_unit_audit' from public.equipment_unit_audit a
    union all select a.imported_at,a.actor_id,'equipment_csv_import','equipment_import',a.import_id::text,null::jsonb,jsonb_build_object('row_count',a.row_count),'legacy','equipment_import_audit' from public.equipment_import_audit a
    union all select coalesce(m.completed_at,m.created_at),m.recorded_by,case when m.completed_at is not null or m.closes_maintenance_id is not null then 'maintenance_completed' else 'maintenance_started' end,'unit_maintenance',coalesce(m.closes_maintenance_id,m.maintenance_id)::text,null::jsonb,jsonb_build_object('maintenance_id',coalesce(m.closes_maintenance_id,m.maintenance_id)),'legacy','unit_maintenance_log' from public.unit_maintenance_log m
  ), filtered as (
    select h.* from history h where (p_start_date is null or h.event_time>=p_start_date::timestamptz)
      and (p_end_date is null or h.event_time<(p_end_date+1)::timestamptz)
      and (p_actor is null or h.actor_id=p_actor) and (p_event_type is null or h.event_type ilike '%'||p_event_type||'%')
      and (nullif(trim(p_search),'') is null or concat_ws(' ',h.event_type,h.entity_type,h.entity_id,h.source_table,h.actor_id::text,h.before_values::text,h.after_values::text) ilike '%'||trim(p_search)||'%')
      and (v_admin or h.source_table='borrowing_workflow_audit'
        or (h.source_table='equipment_unit_audit' and h.event_type in ('equipment_unit_released','equipment_unit_returned'))
        or (h.source_table='phase7_audit_log' and h.event_type in ('request_approved','request_declined','equipment_released','equipment_returned','overdue_flagged','borrowing_status_changed','borrowing_item_status_changed')))
  )
  select (select count(*)::integer from filtered),coalesce((select jsonb_agg(to_jsonb(p) order by p.event_time desc,p.entity_id desc)
    from (select * from filtered order by event_time desc,entity_id desc limit case when p_export then 5000 else 20 end offset case when p_export then 0 else p_page*20 end) p),'[]'::jsonb)
  into v_total,v_rows;
  if p_export then insert into public.phase7_audit_log(actor_id,source,event_type,entity_type,filters,row_count,success)
    values(v_actor,'rpc','audit_log_exported','audit_log',jsonb_build_object('start_date',p_start_date,'end_date',p_end_date,'actor_id',p_actor,'event_type',p_event_type,'search',p_search),jsonb_array_length(v_rows),true); end if;
  return jsonb_build_object('rows',v_rows,'total_count',v_total,'page',case when p_export then 0 else p_page end,'page_size',case when p_export then 5000 else 20 end,'truncated',p_export and v_total>5000);
end; $$;
revoke all on function public.get_phase7_audit_history(integer,date,date,uuid,text,text,boolean) from public, anon;
grant execute on function public.get_phase7_audit_history(integer,date,date,uuid,text,text,boolean) to authenticated;

create or replace function public.get_phase7_report(
  p_report_type text,p_start_date date,p_end_date date,p_page integer default 0,p_export boolean default false
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=(select auth.uid()); v_rows jsonb:='[]'::jsonb; v_headers jsonb; v_total integer:=0; v_days integer; v_limit integer:=case when p_export then 5000 else 100 end; v_offset integer:=case when p_export then 0 else greatest(coalesce(p_page,0),0)*100 end;
begin
  if v_actor is null or not public.is_equipment_manager_user() or not exists(select 1 from public.profiles p where p.id=v_actor and p.account_status='active' and p.role in ('admin','property_custodian')) then raise exception 'Only administrators and property custodians can run reports.'; end if;
  if p_start_date is null or p_end_date is null or p_end_date<p_start_date or p_end_date-p_start_date+1>366 then raise exception 'Choose a valid report period of 366 days or fewer.'; end if;
  if p_page is null or p_page<0 or p_report_type is null or p_report_type not in ('utilization','most_borrowed','overdue','damage_loss') then raise exception 'Choose a valid report type and page.'; end if;
  v_days:=p_end_date-p_start_date+1;
  if p_report_type='utilization' then
    v_headers:=jsonb_build_array('Equipment ID','Equipment','Borrowed unit-days','Available unit-days','Utilization');
    select count(*)::integer into v_total from public.equipment e where e.deleted_at is null;
    select coalesce(jsonb_agg(jsonb_build_array(q.equipment_id,q.equipment_name,q.borrowed_days,q.available_days,q.utilization) order by q.utilization desc,q.equipment_name),'[]'::jsonb) into v_rows from (
      select e.equipment_id,e.equipment_name,coalesce(sum(greatest(0,least(coalesce(bi.returned_at::date,current_date),p_end_date)-greatest(coalesce(bi.issued_at::date,b.request_date::date),p_start_date)+1)*bi.quantity),0)::integer borrowed_days,
        (greatest(e.quantity-e.out_of_service_quantity,0)*v_days)::integer available_days,
        case when greatest(e.quantity-e.out_of_service_quantity,0)*v_days=0 then 0::numeric else round(coalesce(sum(greatest(0,least(coalesce(bi.returned_at::date,current_date),p_end_date)-greatest(coalesce(bi.issued_at::date,b.request_date::date),p_start_date)+1)*bi.quantity),0)::numeric/(greatest(e.quantity-e.out_of_service_quantity,0)*v_days),4) end utilization
      from public.equipment e left join public.borrowing_items bi on bi.equipment_id=e.equipment_id
      left join public.borrowings b on b.borrowing_id=bi.borrowing_id and b.transaction_status in ('released','returned') and coalesce(bi.issued_at::date,b.request_date::date)<=p_end_date and coalesce(bi.returned_at::date,b.expected_return_date::date)>=p_start_date
      where e.deleted_at is null group by e.equipment_id,e.equipment_name,e.quantity,e.out_of_service_quantity order by utilization desc,e.equipment_name limit v_limit offset v_offset
    ) q;
  elsif p_report_type='most_borrowed' then
    v_headers:=jsonb_build_array('Equipment ID','Equipment','Borrowings');
    select count(*)::integer into v_total from (select e.equipment_id from public.equipment e join public.borrowing_items bi using(equipment_id) join public.borrowings b using(borrowing_id) where e.deleted_at is null and b.transaction_status<>'cancelled' and b.request_date::date<=p_end_date and b.expected_return_date::date>=p_start_date group by e.equipment_id) c;
    select coalesce(jsonb_agg(jsonb_build_array(q.equipment_id,q.equipment_name,q.borrowings) order by q.borrowings desc,q.equipment_name),'[]'::jsonb) into v_rows from (
      select e.equipment_id,e.equipment_name,count(distinct b.borrowing_id)::integer borrowings from public.equipment e join public.borrowing_items bi using(equipment_id) join public.borrowings b using(borrowing_id)
      where e.deleted_at is null and b.transaction_status<>'cancelled' and b.request_date::date<=p_end_date and b.expected_return_date::date>=p_start_date
      group by e.equipment_id,e.equipment_name order by borrowings desc,e.equipment_name limit 20) q;
    v_total:=least(v_total,20);
  elsif p_report_type='overdue' then
    v_headers:=jsonb_build_array('Equipment','Borrower','Contact number','Overdue items','Days overdue');
    select count(*)::integer into v_total from (select e.equipment_id,br.borrower_id from public.borrowing_items bi join public.borrowings b using(borrowing_id) join public.borrowers br using(borrower_id) join public.equipment e using(equipment_id)
      where bi.is_overdue and bi.item_status='released' and b.transaction_status='released' and coalesce(bi.overdue_at::date,b.expected_return_date::date) between p_start_date and p_end_date group by e.equipment_id,br.borrower_id) c;
    select coalesce(jsonb_agg(jsonb_build_array(q.equipment_name,q.borrower_name,q.phone,q.item_count,q.days_overdue) order by q.days_overdue desc,q.equipment_name),'[]'::jsonb) into v_rows from (
      select e.equipment_name,concat_ws(' ',br.first_name,br.middle_name,br.last_name) borrower_name,u.phone,count(*)::integer item_count,max(current_date-b.expected_return_date::date)::integer days_overdue
      from public.borrowing_items bi join public.borrowings b using(borrowing_id) join public.borrowers br using(borrower_id) join public.equipment e using(equipment_id) left join auth.users u on u.id=br.user_id
      where bi.is_overdue and bi.item_status='released' and b.transaction_status='released' and coalesce(bi.overdue_at::date,b.expected_return_date::date) between p_start_date and p_end_date
      group by e.equipment_id,e.equipment_name,br.borrower_id,br.first_name,br.middle_name,br.last_name,u.phone order by days_overdue desc,e.equipment_name limit v_limit offset v_offset) q;
  else
    v_headers:=jsonb_build_array('Equipment ID','Equipment','Report status','Damaged units','Lost units');
    select count(*)::integer into v_total from (select e.equipment_id,r.resolution_status from public.damage_loss_reports r join public.borrowing_items bi using(borrowing_item_id) join public.equipment e using(equipment_id) where r.created_at::date between p_start_date and p_end_date group by e.equipment_id,r.resolution_status) c;
    select coalesce(jsonb_agg(jsonb_build_array(q.equipment_id,q.equipment_name,q.resolution_status,q.damaged_units,q.lost_units) order by q.equipment_name,q.resolution_status),'[]'::jsonb) into v_rows from (
      select e.equipment_id,e.equipment_name,r.resolution_status,count(distinct bi.borrowing_item_id) filter(where r.report_type='damage')::integer damaged_units,count(distinct bi.borrowing_item_id) filter(where r.report_type='loss')::integer lost_units
      from public.damage_loss_reports r join public.borrowing_items bi using(borrowing_item_id) join public.equipment e using(equipment_id)
      where r.created_at::date between p_start_date and p_end_date group by e.equipment_id,e.equipment_name,r.resolution_status order by e.equipment_name,r.resolution_status limit v_limit offset v_offset) q;
  end if;
  if p_export then insert into public.phase7_audit_log(actor_id,source,event_type,entity_type,entity_id,filters,row_count,success)
    values(v_actor,'rpc','report_exported','report',p_report_type,jsonb_build_object('start_date',p_start_date,'end_date',p_end_date),jsonb_array_length(v_rows),true); end if;
  return jsonb_build_object('headers',v_headers,'rows',v_rows,'total_count',v_total,'page',case when p_export then 0 else p_page end,'page_size',v_limit,'truncated',p_export and v_total>5000);
end; $$;
revoke all on function public.get_phase7_report(text,date,date,integer,boolean) from public, anon;
grant execute on function public.get_phase7_report(text,date,date,integer,boolean) to authenticated;

notify pgrst,'reload schema';
commit;