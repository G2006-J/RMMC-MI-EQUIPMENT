begin;

create extension if not exists pg_trgm;

alter table public.equipment
  add column if not exists tracking_mode text not null default 'quantity';

alter table public.equipment
  add constraint equipment_tracking_mode_check
    check (tracking_mode in ('quantity', 'unit'));

create table public.equipment_units (
  unit_id bigint generated always as identity primary key,
  equipment_id bigint not null references public.equipment(equipment_id) on delete restrict,
  asset_tag text not null unique check (length(trim(asset_tag)) between 1 and 120),
  serial_number text,
  status text not null default 'available'
    check (status in ('available', 'borrowed', 'maintenance', 'lost', 'retired')),
  notes text check (notes is null or length(notes) <= 1000),
  calibration_due_at date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint equipment_units_serial_number_nonempty
    check (serial_number is null or length(trim(serial_number)) between 1 and 160)
);

create unique index equipment_units_serial_number_uidx
  on public.equipment_units (serial_number)
  where serial_number is not null;
create index equipment_units_equipment_status_idx
  on public.equipment_units (equipment_id, status, unit_id);
create index equipment_units_calibration_due_idx
  on public.equipment_units (calibration_due_at, unit_id)
  where calibration_due_at is not null and status <> 'retired';
create index equipment_units_asset_tag_search_idx
  on public.equipment_units (lower(asset_tag) text_pattern_ops, unit_id);
create index equipment_units_serial_search_idx
  on public.equipment_units (lower(serial_number) text_pattern_ops, unit_id)
  where serial_number is not null;

alter table public.borrowing_items
  add column unit_id bigint references public.equipment_units(unit_id) on delete restrict;
alter table public.borrowing_items
  drop constraint if exists borrowing_items_borrowing_id_equipment_id_key;
create index borrowing_items_unit_id_idx on public.borrowing_items (unit_id);
create unique index borrowing_items_unit_id_uidx
  on public.borrowing_items (unit_id) where unit_id is not null;

create table public.unit_maintenance_log (
  maintenance_id bigint generated always as identity primary key,
  unit_id bigint not null references public.equipment_units(unit_id) on delete restrict,
  reason text not null check (length(trim(reason)) between 1 and 1000),
  started_at timestamptz not null,
  expected_back_at timestamptz,
  completed_at timestamptz,
  recorded_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint unit_maintenance_dates_check
    check (expected_back_at is null or expected_back_at >= started_at),
  constraint unit_maintenance_completion_check
    check (completed_at is null or completed_at >= started_at)
);
create unique index unit_maintenance_one_open_idx
  on public.unit_maintenance_log (unit_id) where completed_at is null;
create index unit_maintenance_due_idx
  on public.unit_maintenance_log (expected_back_at, unit_id) where completed_at is null;

create table public.equipment_unit_audit (
  audit_id bigint generated always as identity primary key,
  unit_id bigint references public.equipment_units(unit_id) on delete restrict,
  equipment_id bigint not null references public.equipment(equipment_id) on delete restrict,
  actor_id uuid references public.profiles(id) on delete set null,
  action text not null check (action in ('insert', 'status_changed', 'retired', 'released', 'returned', 'import')),
  old_values jsonb,
  new_values jsonb not null,
  changed_at timestamptz not null default now()
);
create index equipment_unit_audit_changed_at_idx
  on public.equipment_unit_audit (changed_at desc, audit_id desc);
create index equipment_unit_audit_equipment_idx
  on public.equipment_unit_audit (equipment_id, changed_at desc, audit_id desc);

create table public.equipment_import_audit (
  import_id bigint generated always as identity primary key,
  actor_id uuid not null references public.profiles(id) on delete restrict,
  imported_at timestamptz not null default now(),
  row_count integer not null check (row_count between 1 and 500)
);

alter table public.equipment_units enable row level security;
alter table public.unit_maintenance_log enable row level security;
alter table public.equipment_unit_audit enable row level security;
alter table public.equipment_import_audit enable row level security;
revoke all on public.equipment_units, public.unit_maintenance_log,
  public.equipment_unit_audit, public.equipment_import_audit from anon, authenticated;
grant select on public.equipment_units, public.unit_maintenance_log,
  public.equipment_unit_audit, public.equipment_import_audit to authenticated;

revoke select on public.borrowing_items from public, anon, authenticated;
revoke insert, update, delete on public.borrowing_items from public, anon, authenticated;
grant select (
  borrowing_item_id, borrowing_id, equipment_id, item_status, issued_at, returned_at,
  quantity, released_by, released_at, received_by, condition_at_release,
  release_photo_path, condition_at_return, return_photo_path, is_overdue, overdue_at
) on public.borrowing_items to authenticated;

create policy equipment_units_manager_read on public.equipment_units
  for select to authenticated using (public.is_equipment_manager_user());
create policy unit_maintenance_manager_read on public.unit_maintenance_log
  for select to authenticated using (public.is_equipment_manager_user());
create policy equipment_unit_audit_manager_read on public.equipment_unit_audit
  for select to authenticated using (public.is_equipment_manager_user());
create policy equipment_import_audit_manager_read on public.equipment_import_audit
  for select to authenticated using (public.is_equipment_admin_user());

create or replace function public.prevent_open_unit_maintenance_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'A verified manager is required to change maintenance records.';
  elsif not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can change unit maintenance records.';
  end if;
  if old.completed_at is null then
    raise exception 'An open maintenance record cannot be deleted.';
  end if;
  return old;
end;
$$;
revoke all on function public.prevent_open_unit_maintenance_delete() from public, anon, authenticated;
create trigger prevent_open_unit_maintenance_delete
  before delete on public.unit_maintenance_log
  for each row execute function public.prevent_open_unit_maintenance_delete();

create or replace function public.enforce_equipment_unit_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_equipment_id bigint;
  v_tracking_mode text;
  v_quantity integer;
  v_out_of_service integer;
  v_non_retired integer;
  v_maintenance integer;
  v_actor uuid := (select auth.uid());
begin
  if v_actor is not null and not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can change unit inventory.';
  elsif v_actor is null and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'A verified equipment manager is required to change unit inventory.';
  end if;

  if tg_table_name = 'equipment' then
    v_equipment_id := case when tg_op = 'DELETE' then old.equipment_id else new.equipment_id end;
  elsif tg_op = 'DELETE' then
    v_equipment_id := old.equipment_id;
  else
    v_equipment_id := new.equipment_id;
  end if;

  select e.tracking_mode, e.quantity, e.out_of_service_quantity
    into v_tracking_mode, v_quantity, v_out_of_service
  from public.equipment e
  where e.equipment_id = v_equipment_id;
  if not found or v_tracking_mode <> 'unit' then
    return null;
  end if;

  select count(*) filter (where u.status <> 'retired'),
         count(*) filter (where u.status = 'maintenance')
    into v_non_retired, v_maintenance
  from public.equipment_units u
  where u.equipment_id = v_equipment_id;

  if v_non_retired <> v_quantity then
    raise exception 'Unit-tracked equipment quantity must equal its non-retired unit count.' using errcode = '23514';
  end if;
  if v_maintenance <> v_out_of_service then
    raise exception 'Unit-tracked out-of-service quantity must equal its maintenance unit count.' using errcode = '23514';
  end if;
  return null;
end;
$$;
revoke all on function public.enforce_equipment_unit_count() from public, anon, authenticated;

create constraint trigger equipment_unit_count_equipment_guard
  after insert or update of quantity, tracking_mode, out_of_service_quantity on public.equipment
  deferrable initially deferred for each row
  execute function public.enforce_equipment_unit_count();
create constraint trigger equipment_unit_count_unit_guard
  after insert or update or delete on public.equipment_units
  deferrable initially deferred for each row
  execute function public.enforce_equipment_unit_count();

create or replace function public.guard_borrowing_item_unit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_tracking_mode text;
  v_unit_equipment_id bigint;
  v_unit_status text;
begin
  if v_actor is not null and not public.is_equipment_manager_user()
    and ((tg_op = 'INSERT' and new.unit_id is not null)
      or (tg_op = 'UPDATE' and new.unit_id is distinct from old.unit_id)) then
    raise exception 'Only equipment managers can assign or change equipment units.';
  elsif v_actor is null and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'A verified equipment manager is required to assign equipment units.';
  end if;
  select e.tracking_mode into v_tracking_mode from public.equipment e
  where e.equipment_id = new.equipment_id;
  if new.unit_id is null then
    if v_tracking_mode = 'unit' and new.item_status in ('released', 'returned') then
      raise exception 'Unit-tracked borrowings require a unit assignment through the release and return workflow.';
    end if;
    return new;
  end if;
  select u.equipment_id, u.status into v_unit_equipment_id, v_unit_status
  from public.equipment_units u where u.unit_id = new.unit_id;
  if v_tracking_mode <> 'unit' or v_unit_equipment_id <> new.equipment_id or new.quantity <> 1 then
    raise exception 'A unit assignment must match one unit-tracked equipment item.';
  end if;
  if new.item_status = 'released' and v_unit_status <> 'borrowed' then
    raise exception 'A released borrowing item must have a borrowed unit.';
  end if;
  if new.item_status = 'returned' and v_unit_status = 'borrowed' then
    raise exception 'Return the assigned unit before completing the borrowing item.';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_borrowing_item_unit() from public, anon, authenticated;
create trigger guard_borrowing_item_unit_assignment
  before insert or update of unit_id, item_status, equipment_id, quantity on public.borrowing_items
  for each row execute function public.guard_borrowing_item_unit();

create or replace function public.add_equipment_unit(
  p_equipment_id bigint,
  p_asset_tag text,
  p_serial_number text default null,
  p_notes text default null,
  p_calibration_due_at date default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_mode text;
  v_unit_id bigint;
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can add equipment units.';
  end if;
  if nullif(trim(p_asset_tag), '') is null or length(trim(p_asset_tag)) > 120
    or (p_serial_number is not null and length(trim(p_serial_number)) > 160)
    or (p_notes is not null and length(p_notes) > 1000) then
    raise exception 'Check unit asset tag, serial number, and notes lengths.';
  end if;
  perform 1 from public.equipment e where e.equipment_id = p_equipment_id
    and e.deleted_at is null for update;
  if not found then raise exception 'Equipment not found.'; end if;
  select e.tracking_mode into v_mode from public.equipment e where e.equipment_id = p_equipment_id;
  if v_mode <> 'unit' then raise exception 'Switch the equipment to unit tracking before adding units.'; end if;

  insert into public.equipment_units (equipment_id, asset_tag, serial_number, notes, calibration_due_at)
  values (p_equipment_id, trim(p_asset_tag), nullif(trim(p_serial_number), ''), nullif(trim(p_notes), ''), p_calibration_due_at)
  returning unit_id into v_unit_id;
  update public.equipment set quantity = quantity + 1,
    availability_status = case when quantity + 1 > out_of_service_quantity then 'available' else 'maintenance' end,
    updated_at = now()
  where equipment_id = p_equipment_id;
  update public.equipment e set availability_status = 'available', updated_at = now()
  where e.equipment_id = p_equipment_id and e.availability_status = 'maintenance';
  insert into public.equipment_unit_audit (unit_id, equipment_id, actor_id, action, new_values)
  values (v_unit_id, p_equipment_id, v_actor, 'insert', jsonb_build_object('asset_tag', trim(p_asset_tag), 'status', 'available'));
  return v_unit_id;
end;
$$;
revoke all on function public.add_equipment_unit(bigint, text, text, text, date) from public, anon;
grant execute on function public.add_equipment_unit(bigint, text, text, text, date) to authenticated;

create or replace function public.convert_equipment_to_unit_tracking(p_equipment_id bigint, p_units jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_quantity integer;
  v_out_of_service integer;
  v_mode text;
  v_row_count integer;
  v_maintenance integer;
  v_unit jsonb;
  v_unit_id bigint;
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can enable unit tracking.';
  end if;
  if jsonb_typeof(p_units) is distinct from 'array' or jsonb_array_length(p_units) < 1
    or jsonb_array_length(p_units) > 10000 then
    raise exception 'Provide one unit record for each item in the equipment quantity.';
  end if;
  select tracking_mode, quantity, out_of_service_quantity
    into v_mode, v_quantity, v_out_of_service
  from public.equipment where equipment_id = p_equipment_id and deleted_at is null for update;
  if not found then raise exception 'Equipment not found.'; end if;
  if v_mode <> 'quantity' then raise exception 'Equipment is already unit-tracked.'; end if;
  if exists (select 1 from public.borrowing_items bi
      where bi.equipment_id = p_equipment_id and bi.item_status in ('requested', 'approved', 'released'))
    or exists (select 1 from public.reservations r where r.equipment_id = p_equipment_id
      and r.status in ('pending', 'approved')) then
    raise exception 'Resolve active borrowing and reservation records before converting this equipment.';
  end if;
  select count(*) filter (where value ->> 'status' <> 'retired'),
         count(*) filter (where value ->> 'status' = 'maintenance')
    into v_row_count, v_maintenance
  from jsonb_array_elements(p_units);
  if v_row_count <> v_quantity or v_maintenance <> v_out_of_service then
    raise exception 'Provide exactly quantity non-retired units and preserve the existing out-of-service count.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_units) x
    where nullif(trim(x.value ->> 'asset_tag'), '') is null
      or length(x.value ->> 'asset_tag') > 120
      or coalesce(x.value ->> 'status', 'available') not in ('available', 'maintenance', 'lost', 'retired')
      or (x.value ->> 'serial_number' is not null and length(x.value ->> 'serial_number') > 160)
      or (x.value ->> 'notes' is not null and length(x.value ->> 'notes') > 1000)
  ) then raise exception 'Check unit tags, statuses, serial numbers, and notes.'; end if;
  if exists (select 1 from jsonb_array_elements(p_units) x group by x.value ->> 'asset_tag' having count(*) > 1)
    or exists (select 1 from jsonb_array_elements(p_units) x
      where exists (select 1 from public.equipment_units u where u.asset_tag = x.value ->> 'asset_tag')) then
    raise exception 'Unit asset tags must be unique.';
  end if;
  if exists (select 1 from jsonb_array_elements(p_units) x where x.value ->> 'serial_number' is not null
      group by x.value ->> 'serial_number' having count(*) > 1)
    or exists (select 1 from jsonb_array_elements(p_units) x
      where x.value ->> 'serial_number' is not null and exists (
        select 1 from public.equipment_units u where u.serial_number = x.value ->> 'serial_number')) then
    raise exception 'Unit serial numbers must be unique.';
  end if;

  update public.equipment set tracking_mode = 'unit', updated_at = now()
  where equipment_id = p_equipment_id;
  for v_unit in select value from jsonb_array_elements(p_units)
  loop
    insert into public.equipment_units (equipment_id, asset_tag, serial_number, status, notes, calibration_due_at)
    values (p_equipment_id, trim(v_unit ->> 'asset_tag'), nullif(trim(v_unit ->> 'serial_number'), ''),
      coalesce(v_unit ->> 'status', 'available'), nullif(trim(v_unit ->> 'notes'), ''),
      nullif(v_unit ->> 'calibration_due_at', '')::date)
    returning unit_id into v_unit_id;
    insert into public.equipment_unit_audit (unit_id, equipment_id, actor_id, action, new_values)
    values (v_unit_id, p_equipment_id, v_actor, 'insert',
      jsonb_build_object('asset_tag', v_unit ->> 'asset_tag', 'status', coalesce(v_unit ->> 'status', 'available')));
    if coalesce(v_unit ->> 'status', 'available') = 'maintenance' then
      insert into public.unit_maintenance_log (unit_id, reason, started_at, recorded_by)
      values (v_unit_id, left(coalesce(nullif(trim(v_unit ->> 'notes'), ''), 'Maintenance at unit-tracking conversion'), 1000), now(), v_actor);
    end if;
  end loop;
  update public.equipment e set availability_status = case
    when e.quantity = 0 then 'retired'
    when exists (select 1 from public.equipment_units u where u.equipment_id = e.equipment_id and u.status = 'available') then 'available'
    when exists (select 1 from public.equipment_units u where u.equipment_id = e.equipment_id and u.status = 'borrowed') then 'borrowed'
    else 'maintenance'
  end, updated_at = now()
  where e.equipment_id = p_equipment_id;
end;
$$;
revoke all on function public.convert_equipment_to_unit_tracking(bigint, jsonb) from public, anon;
grant execute on function public.convert_equipment_to_unit_tracking(bigint, jsonb) to authenticated;

create or replace function public.set_equipment_unit_status(
  p_unit_id bigint,
  p_status text,
  p_reason text default null,
  p_started_at timestamptz default now(),
  p_expected_back_at timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_equipment_id bigint;
  v_old_status text;
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can change unit status.';
  end if;
  if p_status is null or p_status not in ('available', 'maintenance', 'retired') then
    raise exception 'Use release and return workflows for borrowed or lost units.';
  end if;
  select equipment_id into v_equipment_id from public.equipment_units
  where unit_id = p_unit_id;
  if not found then raise exception 'Equipment unit not found.'; end if;
  perform 1 from public.equipment where equipment_id = v_equipment_id for update;
  select status into v_old_status from public.equipment_units
  where unit_id = p_unit_id for update;
  if v_old_status in ('borrowed', 'lost', 'retired') then
    raise exception 'Borrowed or lost units cannot be changed through maintenance controls.';
  end if;
  if v_old_status = p_status then raise exception 'The unit is already in that status.'; end if;
  if p_status = 'maintenance' and nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required to place a unit in maintenance.';
  end if;
  if p_status = 'maintenance' then
    update public.equipment_units set status = p_status, updated_at = now() where unit_id = p_unit_id;
    update public.equipment set out_of_service_quantity = out_of_service_quantity + 1, updated_at = now()
      where equipment_id = v_equipment_id;
    insert into public.unit_maintenance_log (unit_id, reason, started_at, expected_back_at, recorded_by)
    values (p_unit_id, trim(p_reason), coalesce(p_started_at, now()), p_expected_back_at, v_actor);
  else
    update public.equipment_units set status = p_status, updated_at = now() where unit_id = p_unit_id;
    if v_old_status = 'maintenance' then
      update public.unit_maintenance_log set completed_at = now()
      where unit_id = p_unit_id and completed_at is null;
      update public.equipment set out_of_service_quantity = out_of_service_quantity - 1, updated_at = now()
      where equipment_id = v_equipment_id;
    end if;
    if p_status = 'retired' then
      update public.equipment set quantity = quantity - 1, updated_at = now()
      where equipment_id = v_equipment_id;
    end if;
  end if;
  update public.equipment e
  set availability_status = case
    when e.availability_status = 'retired' then 'retired'
    when e.tracking_mode = 'unit' and e.quantity = 0 then 'retired'
    when e.tracking_mode = 'unit' and not exists (
      select 1 from public.equipment_units u
      where u.equipment_id = e.equipment_id and u.status in ('available', 'borrowed')
    ) then 'maintenance'
    when e.tracking_mode = 'unit' and not exists (
      select 1 from public.equipment_units u
      where u.equipment_id = e.equipment_id and u.status = 'available'
    ) then 'borrowed'
    when e.quantity - e.out_of_service_quantity <= 0 then 'maintenance'
    else 'available'
  end,
  updated_at = now()
  where e.equipment_id = v_equipment_id;
  insert into public.equipment_unit_audit (unit_id, equipment_id, actor_id, action, old_values, new_values)
  values (p_unit_id, v_equipment_id, v_actor,
    case when p_status = 'retired' then 'retired' else 'status_changed' end,
    jsonb_build_object('status', v_old_status),
    jsonb_build_object('status', p_status, 'reason', nullif(trim(p_reason), ''), 'expected_back_at', p_expected_back_at));
end;
$$;
revoke all on function public.set_equipment_unit_status(bigint, text, text, timestamptz, timestamptz) from public, anon;
grant execute on function public.set_equipment_unit_status(bigint, text, text, timestamptz, timestamptz) to authenticated;

create or replace function public.lookup_equipment_unit_by_tag(p_asset_tag text)
returns table (unit_id bigint, equipment_id bigint, asset_tag text, status text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can look up unit tags.';
  end if;
  return query select u.unit_id, u.equipment_id, u.asset_tag, u.status
  from public.equipment_units u where u.asset_tag = trim(p_asset_tag);
end;
$$;
revoke all on function public.lookup_equipment_unit_by_tag(text) from public, anon;
grant execute on function public.lookup_equipment_unit_by_tag(text) to authenticated;

create or replace function public.equipment_unit_qr_payload(p_unit_id bigint)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can generate unit labels.';
  end if;
  return (select u.asset_tag from public.equipment_units u where u.unit_id = p_unit_id);
end;
$$;
revoke all on function public.equipment_unit_qr_payload(bigint) from public, anon;
grant execute on function public.equipment_unit_qr_payload(bigint) to authenticated;

create or replace function public.set_equipment_unit_calibration_due(p_unit_id bigint, p_due_date date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_equipment_id bigint;
  v_old_due date;
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can change calibration due dates.';
  end if;
  select equipment_id into v_equipment_id from public.equipment_units where unit_id = p_unit_id;
  if not found then raise exception 'Equipment unit not found.'; end if;
  perform 1 from public.equipment where equipment_id = v_equipment_id for update;
  select calibration_due_at into v_old_due from public.equipment_units where unit_id = p_unit_id for update;
  update public.equipment_units set calibration_due_at = p_due_date, updated_at = now() where unit_id = p_unit_id;
  insert into public.equipment_unit_audit (unit_id, equipment_id, actor_id, action, old_values, new_values)
  values (p_unit_id, v_equipment_id, v_actor, 'status_changed',
    jsonb_build_object('calibration_due_at', v_old_due), jsonb_build_object('calibration_due_at', p_due_date));
end;
$$;
revoke all on function public.set_equipment_unit_calibration_due(bigint, date) from public, anon;
grant execute on function public.set_equipment_unit_calibration_due(bigint, date) to authenticated;

create or replace function public.equipment_units_due_for_calibration(p_days integer default 14)
returns table (unit_id bigint, equipment_id bigint, asset_tag text, calibration_due_at date, status text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can view calibration dates.';
  end if;
  if p_days < 0 or p_days > 365 then raise exception 'Choose a due window from 0 to 365 days.'; end if;
  return query select u.unit_id, u.equipment_id, u.asset_tag, u.calibration_due_at, u.status
  from public.equipment_units u
  where u.status <> 'retired' and u.calibration_due_at between current_date and current_date + p_days
  order by u.calibration_due_at, u.unit_id;
end;
$$;
revoke all on function public.equipment_units_due_for_calibration(integer) from public, anon;
grant execute on function public.equipment_units_due_for_calibration(integer) to authenticated;

create or replace function public.search_equipment_units_page(
    p_search text default null,
    p_status text default null,
    p_after_unit_id bigint default 0
  )
  returns table (
    unit_id bigint,
    equipment_id bigint,
    equipment_name text,
    asset_tag text,
    serial_number text,
    status text,
    notes text,
    calibration_due_at date,
    expected_back_at timestamptz
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
  as $$
  begin
    if (select auth.uid()) is null or not public.is_equipment_manager_user() then
      raise exception 'Only administrators and property custodians can search equipment units.';
    end if;
    return query select u.unit_id, u.equipment_id, e.equipment_name::text, u.asset_tag,
      u.serial_number, u.status, u.notes, u.calibration_due_at, m.expected_back_at
    from public.equipment_units u join public.equipment e using (equipment_id)
    left join public.unit_maintenance_log m on m.unit_id = u.unit_id and m.completed_at is null
    where u.unit_id > coalesce(p_after_unit_id, 0)
      and (p_status is null or u.status = p_status)
      and (nullif(trim(p_search), '') is null or lower(u.asset_tag) like lower(trim(p_search)) || '%'
        or lower(coalesce(u.serial_number, '')) like lower(trim(p_search)) || '%'
        or lower(e.equipment_name) like lower(trim(p_search)) || '%')
    order by u.unit_id limit 20;
  end;
  $$;
  revoke all on function public.search_equipment_units_page(text, text, bigint) from public, anon;
  grant execute on function public.search_equipment_units_page(text, text, bigint) to authenticated;

  create or replace function public.list_borrowing_unit_assignments(p_borrowing_id bigint)
  returns table (borrowing_item_id bigint, equipment_id bigint, unit_id bigint, asset_tag text, unit_status text)
  language plpgsql
  stable
  security definer
  set search_path = ''
  as $$
  begin
    if (select auth.uid()) is null or not public.is_equipment_manager_user() then
      raise exception 'Only administrators and property custodians can view assigned units.';
    end if;
    return query select bi.borrowing_item_id, bi.equipment_id, u.unit_id, u.asset_tag, u.status
    from public.borrowing_items bi join public.equipment_units u on u.unit_id = bi.unit_id
    where bi.borrowing_id = p_borrowing_id order by bi.borrowing_item_id;
  end;
  $$;
  revoke all on function public.list_borrowing_unit_assignments(bigint) from public, anon;
  grant execute on function public.list_borrowing_unit_assignments(bigint) to authenticated;

  create or replace function public.search_equipment_page(
  p_search text default null,
  p_category_id bigint default null,
  p_after_name text default null,
  p_after_id bigint default null
)
returns table (
  equipment_id bigint,
  asset_code text,
  equipment_name text,
  category_id bigint,
  category_name text,
  quantity integer,
  out_of_service_quantity integer,
  tracking_mode text,
  availability_status text,
  available_quantity integer,
  image_url text,
  storage_location text,
  brand text,
  model text,
  description text,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_verified_active_user() then
    raise exception 'Sign in with an active account to search equipment.';
  end if;
  if not exists (select 1 from public.profiles p where p.id = (select auth.uid())
    and p.role in ('staff', 'admin', 'property_custodian')) then
    raise exception 'This account cannot search equipment.';
  end if;
  return query
  select e.equipment_id, e.asset_code::text, e.equipment_name::text, e.category_id,
    c.category_name::text, e.quantity, e.out_of_service_quantity, e.tracking_mode, e.availability_status,
    case when e.tracking_mode = 'unit' then greatest(0, (
      select count(*)::integer from public.equipment_units u
      where u.equipment_id = e.equipment_id and u.status = 'available'
    ) - coalesce(occupied.amount, 0)) else greatest(0, e.quantity - e.out_of_service_quantity - coalesce(occupied.amount, 0))::integer end,
    e.image_url::text, e.storage_location::text, e.brand::text, e.model::text,
    e.description::text, count(*) over ()
  from public.equipment e join public.categories c using (category_id)
  left join lateral (
    select coalesce(sum(bi.quantity), 0)::integer amount from public.borrowing_items bi
    join public.borrowings b using (borrowing_id)
    where bi.equipment_id = e.equipment_id and b.transaction_status in ('approved', 'released')
      and b.request_date::date <= current_date and b.expected_return_date::date >= current_date
      and (e.tracking_mode <> 'unit' or b.transaction_status = 'approved')
  ) occupied on true
  where e.deleted_at is null
    and (p_category_id is null or e.category_id = p_category_id)
    and (nullif(trim(p_search), '') is null or lower(e.equipment_name) like lower(trim(p_search)) || '%'
      or lower(e.asset_code) like lower(trim(p_search)) || '%'
      or lower(coalesce(e.storage_location, '')) like lower(trim(p_search)) || '%')
    and (p_after_name is null or (e.equipment_name, e.equipment_id) > (p_after_name, p_after_id))
  order by e.equipment_name, e.equipment_id
  limit 20;
end;
$$;
revoke all on function public.search_equipment_page(text, bigint, text, bigint) from public, anon;
grant execute on function public.search_equipment_page(text, bigint, text, bigint) to authenticated;

create or replace function public.my_current_unit_tags()
returns table (asset_tag text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
begin
  if v_actor is null or not public.is_verified_active_user()
    or not exists (select 1 from public.profiles p where p.id = v_actor and p.role = 'staff') then
    raise exception 'Sign in with an active account to view held unit tags.';
  end if;
  return query select u.asset_tag
  from public.equipment_units u
  join public.borrowing_items bi on bi.unit_id = u.unit_id
  join public.borrowings b using (borrowing_id)
  join public.borrowers br using (borrower_id)
  where br.user_id = v_actor and b.transaction_status = 'released' and bi.item_status = 'released';
end;
$$;
revoke all on function public.my_current_unit_tags() from public, anon;
grant execute on function public.my_current_unit_tags() to authenticated;

create or replace function public.import_equipment_csv(p_rows jsonb, p_dry_run boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_rows jsonb := '[]'::jsonb;
  v_results jsonb := '[]'::jsonb;
  v_row record;
  v_item jsonb;
  v_errors text[];
  v_asset_code text;
  v_name text;
  v_category text;
  v_mode text;
  v_quantity integer;
  v_tag text;
  v_serial text;
  v_status text;
  v_notes text;
  v_due date;
  v_line integer := 0;
  v_row_count integer;
  v_maintenance integer;
  v_equipment_id bigint;
  v_category_id bigint;
begin
  if v_actor is null or not public.is_equipment_admin_user() then
    raise exception 'Only administrators can import equipment.';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'Import rows must be provided as a JSON array.';
  end if;
  if jsonb_array_length(p_rows) < 1 or jsonb_array_length(p_rows) > 500 then
    raise exception 'Import between 1 and 500 CSV rows.';
  end if;
  if octet_length(p_rows::text) > 1048576 then
    raise exception 'CSV imports cannot exceed 1 MB.';
  end if;

  for v_row in select value, ordinality::integer + 1 as line_number
    from jsonb_array_elements(p_rows) with ordinality
  loop
    v_line := v_row.line_number;
    v_item := v_row.value;
    v_errors := '{}'::text[];
    v_asset_code := regexp_replace(coalesce(v_item ->> 'asset_code', ''), '^[[:space:]]*[=+@-]+', '');
    v_name := regexp_replace(coalesce(v_item ->> 'equipment_name', ''), '^[[:space:]]*[=+@-]+', '');
    v_category := regexp_replace(coalesce(v_item ->> 'category_name', ''), '^[[:space:]]*[=+@-]+', '');
    v_mode := coalesce(nullif(regexp_replace(coalesce(v_item ->> 'tracking_mode', ''), '^[[:space:]]*[=+@-]+', ''), ''), 'quantity');
    v_tag := nullif(regexp_replace(coalesce(v_item ->> 'unit_asset_tag', ''), '^[[:space:]]*[=+@-]+', ''), '');
    v_serial := nullif(regexp_replace(coalesce(v_item ->> 'serial_number', ''), '^[[:space:]]*[=+@-]+', ''), '');
    v_status := coalesce(nullif(regexp_replace(coalesce(v_item ->> 'unit_status', ''), '^[[:space:]]*[=+@-]+', ''), ''), 'available');
    v_notes := nullif(regexp_replace(coalesce(v_item ->> 'notes', ''), '^[[:space:]]*[=+@-]+', ''), '');
    v_due := null;
    begin
      v_due := nullif(v_item ->> 'calibration_due_at', '')::date;
    exception when others then
      v_errors := array_append(v_errors, 'Calibration due date must be a valid ISO date.');
    end;
    v_quantity := null;
    begin
      v_quantity := nullif(v_item ->> 'quantity', '')::integer;
    exception when others then
      v_errors := array_append(v_errors, 'Quantity must be a whole number.');
    end;
    if nullif(trim(v_asset_code), '') is null or length(v_asset_code) > 80 then v_errors := array_append(v_errors, 'Asset code is required and must be at most 80 characters.'); end if;
    if nullif(trim(v_name), '') is null or length(v_name) > 160 then v_errors := array_append(v_errors, 'Equipment name is required and must be at most 160 characters.'); end if;
    if nullif(trim(v_category), '') is null or not exists (select 1 from public.categories c where c.category_name = trim(v_category)) then v_errors := array_append(v_errors, 'Category must match an existing category.'); end if;
    if v_mode not in ('quantity', 'unit') then v_errors := array_append(v_errors, 'Tracking mode must be quantity or unit.'); end if;
    if v_quantity is null
      or (v_mode = 'quantity' and v_quantity < 1)
      or (v_mode = 'unit' and v_quantity < 0)
      or v_quantity > 10000 then
      v_errors := array_append(v_errors, 'Quantity is outside the allowed range for this tracking mode.');
    end if;
    if v_mode = 'unit' and v_tag is null then v_errors := array_append(v_errors, 'Unit-tracked rows require a unit asset tag.'); end if;
    if v_mode = 'quantity' and v_tag is not null then v_errors := array_append(v_errors, 'Quantity-tracked rows must not include a unit asset tag.'); end if;
    if v_mode = 'unit' and v_status not in ('available', 'maintenance', 'lost', 'retired') then v_errors := array_append(v_errors, 'Unit status must be available, maintenance, lost, or retired.'); end if;
    if v_mode = 'unit' and v_status = 'maintenance' and v_notes is null then v_errors := array_append(v_errors, 'Maintenance units require a reason in the notes column.'); end if;
    if v_tag is not null and length(v_tag) > 120 then v_errors := array_append(v_errors, 'Unit asset tag must be at most 120 characters.'); end if;
    if v_serial is not null and length(v_serial) > 160 then v_errors := array_append(v_errors, 'Serial number must be at most 160 characters.'); end if;
    if v_notes is not null and length(v_notes) > 1000 then v_errors := array_append(v_errors, 'Unit notes must be at most 1000 characters.'); end if;
    if exists (select 1 from public.equipment e where e.asset_code = trim(v_asset_code)) then v_errors := array_append(v_errors, 'Equipment asset code already exists.'); end if;
    if v_tag is not null and exists (select 1 from public.equipment_units u where u.asset_tag = trim(v_tag)) then v_errors := array_append(v_errors, 'Unit asset tag already exists.'); end if;
    if v_serial is not null and exists (select 1 from public.equipment_units u where u.serial_number = trim(v_serial)) then v_errors := array_append(v_errors, 'Unit serial number already exists.'); end if;

    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'line', v_line, 'asset_code', trim(v_asset_code), 'equipment_name', trim(v_name),
      'category_name', trim(v_category), 'tracking_mode', v_mode, 'quantity', v_quantity,
      'unit_asset_tag', nullif(trim(v_tag), ''), 'serial_number', nullif(trim(v_serial), ''),
      'unit_status', v_status, 'notes', nullif(trim(v_notes), ''), 'calibration_due_at', v_due,
      'errors', to_jsonb(v_errors)
    ));
  end loop;

  for v_item in select value from jsonb_array_elements(v_rows)
  loop
    v_errors := array(select jsonb_array_elements_text(v_item -> 'errors'));
    v_asset_code := v_item ->> 'asset_code';
    v_tag := v_item ->> 'unit_asset_tag';
    if v_tag is not null and exists (
      select 1 from jsonb_array_elements(v_rows) other
      where other.value ->> 'unit_asset_tag' = v_tag
        and (other.value ->> 'line')::integer < (v_item ->> 'line')::integer
    ) then v_errors := array_append(v_errors, 'Unit asset tag is duplicated in this file.'); end if;
    if v_item ->> 'serial_number' is not null and exists (
      select 1 from jsonb_array_elements(v_rows) other
      where other.value ->> 'serial_number' = v_item ->> 'serial_number'
        and (other.value ->> 'line')::integer < (v_item ->> 'line')::integer
    ) then v_errors := array_append(v_errors, 'Serial number is duplicated in this file.'); end if;
    if v_item ->> 'tracking_mode' = 'unit' then
      select count(*) filter (where other.value ->> 'unit_status' <> 'retired') into v_row_count
      from jsonb_array_elements(v_rows) other where other.value ->> 'asset_code' = v_asset_code;
      if v_row_count <> (v_item ->> 'quantity')::integer then
        v_errors := array_append(v_errors, 'Unit-tracked equipment needs quantity non-retired unit rows in the file.');
      end if;
      if exists (select 1 from jsonb_array_elements(v_rows) other
        where other.value ->> 'asset_code' = v_asset_code
          and (other.value ->> 'tracking_mode' <> v_item ->> 'tracking_mode'
            or other.value ->> 'equipment_name' <> v_item ->> 'equipment_name'
            or other.value ->> 'category_name' <> v_item ->> 'category_name'
            or other.value ->> 'quantity' <> v_item ->> 'quantity')) then
        v_errors := array_append(v_errors, 'Rows for the same equipment must use matching details and quantity.');
      end if;
    else
      select count(*) into v_row_count from jsonb_array_elements(v_rows) other
      where other.value ->> 'asset_code' = v_asset_code;
      if v_row_count <> 1 then
        v_errors := array_append(v_errors, 'Quantity-tracked equipment must use exactly one row in the file.');
      end if;
    end if;
    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'line', (v_item ->> 'line')::integer,
      'valid', cardinality(v_errors) = 0,
      'errors', to_jsonb(v_errors)
    ));
  end loop;

  if exists (select 1 from jsonb_array_elements(v_results) r where not (r.value ->> 'valid')::boolean) then
    return jsonb_build_object('ok', false, 'rows', v_results);
  end if;
  if p_dry_run then return jsonb_build_object('ok', true, 'rows', v_results); end if;

  for v_item in
    select distinct on (value ->> 'asset_code') value
    from jsonb_array_elements(v_rows) order by value ->> 'asset_code', (value ->> 'line')::integer
  loop
    select category_id into v_category_id from public.categories where category_name = v_item ->> 'category_name';
    if v_item ->> 'tracking_mode' = 'unit' then
      select count(*) filter (where value ->> 'unit_status' = 'maintenance')::integer into v_maintenance
      from jsonb_array_elements(v_rows) where value ->> 'asset_code' = v_item ->> 'asset_code';
    else
      v_maintenance := 0;
    end if;
    insert into public.equipment (
      asset_code, equipment_name, category_id, quantity, out_of_service_quantity, tracking_mode, availability_status
    ) values (
      v_item ->> 'asset_code', v_item ->> 'equipment_name', v_category_id,
      (v_item ->> 'quantity')::integer, v_maintenance, v_item ->> 'tracking_mode',
      case when v_item ->> 'tracking_mode' = 'unit' and (v_item ->> 'quantity')::integer = 0 then 'retired'
        when v_item ->> 'tracking_mode' = 'unit'
        and not exists (select 1 from jsonb_array_elements(v_rows) unit_row
          where unit_row.value ->> 'asset_code' = v_item ->> 'asset_code'
            and unit_row.value ->> 'unit_status' = 'available') then 'maintenance'
        when v_item ->> 'tracking_mode' = 'quantity'
          and v_maintenance = (v_item ->> 'quantity')::integer then 'maintenance'
        else 'available' end
    ) returning equipment_id into v_equipment_id;
    if v_item ->> 'tracking_mode' = 'unit' then
      insert into public.equipment_units (equipment_id, asset_tag, serial_number, status, notes, calibration_due_at)
      select v_equipment_id, value ->> 'unit_asset_tag', value ->> 'serial_number', value ->> 'unit_status',
        value ->> 'notes', nullif(value ->> 'calibration_due_at', '')::date
      from jsonb_array_elements(v_rows) where value ->> 'asset_code' = v_item ->> 'asset_code';
      insert into public.equipment_unit_audit (unit_id, equipment_id, actor_id, action, new_values)
      select u.unit_id, v_equipment_id, v_actor, 'import',
        jsonb_build_object('asset_tag', u.asset_tag, 'status', u.status)
      from public.equipment_units u where u.equipment_id = v_equipment_id;
      insert into public.unit_maintenance_log (unit_id, reason, started_at, recorded_by)
      select u.unit_id, left(coalesce(nullif(trim(u.notes), ''), 'Maintenance imported from CSV'), 1000), now(), v_actor
      from public.equipment_units u where u.equipment_id = v_equipment_id and u.status = 'maintenance';
    end if;
  end loop;
  select count(*) into v_row_count from jsonb_array_elements(p_rows);
  insert into public.equipment_import_audit (actor_id, row_count) values (v_actor, v_row_count);
  return jsonb_build_object('ok', true, 'rows', v_results, 'imported_rows', v_row_count);
end;
$$;
revoke all on function public.import_equipment_csv(jsonb, boolean) from public, anon;
grant execute on function public.import_equipment_csv(jsonb, boolean) to authenticated;

create or replace function public.equipment_period_has_capacity(
  p_equipment_id bigint,
  p_start_date date,
  p_end_date date,
  p_requested_quantity integer,
  p_exclude_borrowing_id bigint default null,
  p_exclude_reservation_id bigint default null
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_mode text;
  v_quantity integer;
  v_oos integer;
  v_status text;
  v_capacity integer;
begin
  if (select auth.uid()) is null or not public.is_verified_active_user()
    or not exists (select 1 from public.profiles p where p.id = (select auth.uid())
      and p.role in ('admin', 'property_custodian', 'staff')) then return false; end if;
  select e.tracking_mode, e.quantity, e.out_of_service_quantity, e.availability_status
    into v_mode, v_quantity, v_oos, v_status from public.equipment e
    where e.equipment_id = p_equipment_id and e.deleted_at is null;
  if not found or p_requested_quantity is null or p_requested_quantity < 1
    or p_start_date is null or p_end_date is null or p_end_date < p_start_date
    or (v_mode = 'quantity' and v_status in ('maintenance', 'retired')) then return false; end if;
  if v_mode = 'unit' then
    select count(*)::integer into v_capacity from public.equipment_units u
    where u.equipment_id = p_equipment_id and u.status in ('available', 'borrowed');
  else
    v_capacity := v_quantity - v_oos;
  end if;
  if v_capacity < p_requested_quantity then return false; end if;
  return not exists (
    with occupied as (
      select b.request_date::date as start_date,
        case when b.expected_return_date::date < current_date then 'infinity'::date else b.expected_return_date::date end as end_date,
        bi.quantity
      from public.borrowings b join public.borrowing_items bi using (borrowing_id)
      where bi.equipment_id = p_equipment_id and b.transaction_status in ('approved', 'released')
        and (p_exclude_borrowing_id is null or b.borrowing_id <> p_exclude_borrowing_id)
        and (v_mode <> 'unit' or bi.item_status in ('approved', 'released'))
      union all
      select r.start_date, r.end_date, r.quantity from public.reservations r
      where r.equipment_id = p_equipment_id and r.status = 'approved'
        and (p_exclude_reservation_id is null or r.reservation_id <> p_exclude_reservation_id)
    ), candidates as (
      select p_start_date as d union select o.start_date from occupied o
      where o.start_date > p_start_date and o.start_date <= p_end_date
    )
    select 1 from candidates c where (
      select coalesce(sum(o.quantity), 0) from occupied o
      where o.start_date <= c.d and o.end_date >= c.d
    ) + p_requested_quantity > v_capacity
  );
end;
$$;
revoke all on function public.equipment_period_has_capacity(bigint, date, date, integer, bigint, bigint) from public, anon, authenticated;

create or replace function public.equipment_period_has_approval_capacity(
  p_equipment_id bigint,
  p_start_date date,
  p_end_date date,
  p_requested_quantity integer,
  p_exclude_borrowing_id bigint default null,
  p_exclude_reservation_id bigint default null
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then return false; end if;
  return public.equipment_period_has_capacity(
    p_equipment_id, p_start_date, p_end_date, p_requested_quantity,
    p_exclude_borrowing_id, p_exclude_reservation_id
  );
end;
$$;
revoke all on function public.equipment_period_has_approval_capacity(bigint, date, date, integer, bigint, bigint) from public, anon, authenticated;

create or replace function public.equipment_available_quantities()
returns table (equipment_id bigint, available_quantity integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_verified_active_user()
    or not exists (select 1 from public.profiles p where p.id = (select auth.uid())
      and p.role in ('staff', 'admin', 'property_custodian')) then
    raise exception 'Sign in with an active account to view availability.';
  end if;
  return query
  select e.equipment_id,
    case when e.tracking_mode = 'quantity' and e.availability_status in ('maintenance', 'retired') then 0
      when e.tracking_mode = 'unit' then greatest(0,
        (select count(*)::integer from public.equipment_units u
          where u.equipment_id = e.equipment_id and u.status = 'available')
        - coalesce(occupied.amount, 0))
      else greatest(0, e.quantity - e.out_of_service_quantity - coalesce(occupied.amount, 0))
    end::integer
  from public.equipment e
  left join lateral (
    select sum(x.amount)::integer amount from (
      select coalesce(sum(bi.quantity), 0)::integer amount from public.borrowing_items bi
      join public.borrowings b using (borrowing_id)
      where bi.equipment_id = e.equipment_id
        and b.transaction_status in ('approved', 'released')
        and (e.tracking_mode <> 'unit' or b.transaction_status = 'approved')
        and b.request_date::date <= current_date and b.expected_return_date::date >= current_date
      union all
      select coalesce(sum(r.quantity), 0)::integer from public.reservations r
      where r.equipment_id = e.equipment_id and r.status = 'approved'
        and r.start_date <= current_date and r.end_date >= current_date
    ) x
  ) occupied on true
  where e.deleted_at is null;
end;
$$;
revoke all on function public.equipment_available_quantities() from public, anon;
grant execute on function public.equipment_available_quantities() to authenticated;

create or replace function public.request_equipment_borrowing(
  p_equipment_id bigint,
  p_purpose text,
  p_destination text,
  p_expected_return_date timestamptz,
  p_quantity integer
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_borrower bigint;
  v_borrowing bigint;
  v_mode text;
  v_start_date date := current_date;
  v_end_date date := p_expected_return_date::date;
begin
  if v_user is null or not public.is_verified_active_user()
    or not exists (select 1 from public.profiles p where p.id = v_user and p.role = 'staff') then
    raise exception 'Sign in with a verified, active borrower account before requesting equipment.';
  end if;
  v_borrower := public.current_borrower_id();
  if v_borrower is null then raise exception 'Your borrower account is pending approval or inactive.'; end if;
  if p_quantity is null or p_quantity < 1 or nullif(trim(p_purpose), '') is null
    or nullif(trim(p_destination), '') is null or p_expected_return_date is null
    or p_expected_return_date <= now() then raise exception 'Check the request details and return date.'; end if;
  perform 1 from public.equipment e where e.equipment_id = p_equipment_id
    and e.deleted_at is null
    and (e.tracking_mode = 'unit' or e.availability_status not in ('maintenance', 'retired')) for update;
  if not found then raise exception 'This equipment is not currently available.'; end if;
  select tracking_mode into v_mode from public.equipment where equipment_id = p_equipment_id;
  if not public.equipment_period_has_capacity(p_equipment_id, v_start_date, v_end_date, p_quantity, null, null) then
    raise exception 'There are not enough units available for the requested period.';
  end if;
  insert into public.borrowings (transaction_code, borrower_id, processed_by, purpose, destination, expected_return_date)
  values ('BR-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
    v_borrower, v_user, trim(p_purpose), trim(p_destination), p_expected_return_date)
  returning borrowing_id into v_borrowing;
  if v_mode = 'unit' then
    insert into public.borrowing_items (borrowing_id, equipment_id, item_status, quantity)
    select v_borrowing, p_equipment_id, 'requested', 1 from generate_series(1, p_quantity);
  else
    insert into public.borrowing_items (borrowing_id, equipment_id, item_status, quantity)
    values (v_borrowing, p_equipment_id, 'requested', p_quantity);
  end if;
  return v_borrowing;
end;
$$;
revoke all on function public.request_equipment_borrowing(bigint, text, text, timestamptz, integer) from public, anon;
grant execute on function public.request_equipment_borrowing(bigint, text, text, timestamptz, integer) to authenticated;

create or replace function public.release_equipment_borrowing_units(
  p_borrowing_id bigint,
  p_assignments jsonb,
  p_condition text,
  p_photo_path text default null,
  p_condition_notes text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_status text;
  v_assignment record;
  v_item_count integer;
  v_assignment_count integer;
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can release equipment.';
  end if;
  if p_condition is null or p_condition not in ('good', 'fair', 'damaged') then raise exception 'Choose a valid release condition.'; end if;
  if not public.workflow_photo_path_is_valid(p_photo_path, v_actor) then raise exception 'The release photo path is invalid.'; end if;
  if p_condition = 'damaged' and nullif(trim(p_condition_notes), '') is null then raise exception 'Add a damage description.'; end if;
  if jsonb_typeof(p_assignments) <> 'array' then raise exception 'Select one available unit for each unit-tracked item.'; end if;

  perform e.equipment_id from public.equipment e
  where e.equipment_id in (
    select bi.equipment_id from public.borrowing_items bi where bi.borrowing_id = p_borrowing_id
    union
    select u.equipment_id from jsonb_array_elements(p_assignments) x
    join public.equipment_units u on u.unit_id = (x.value ->> 'unit_id')::bigint
  )
  order by e.equipment_id for update;
  for v_assignment in
    select (x.value ->> 'unit_id')::bigint unit_id
    from jsonb_array_elements(p_assignments) x order by (x.value ->> 'unit_id')::bigint
  loop
    perform 1 from public.equipment_units u where u.unit_id = v_assignment.unit_id for update;
    if not found then raise exception 'A selected unit was not found.'; end if;
  end loop;
  select transaction_status into v_status from public.borrowings where borrowing_id = p_borrowing_id for update;
  if not found or v_status <> 'approved' then raise exception 'Only approved borrowings can be released.'; end if;
  select count(*) into v_item_count from public.borrowing_items bi
  join public.equipment e using (equipment_id)
  where bi.borrowing_id = p_borrowing_id and e.tracking_mode = 'unit' and bi.item_status = 'approved';
  if exists (select 1 from public.borrowing_items bi where bi.borrowing_id = p_borrowing_id and bi.item_status <> 'approved') then
    raise exception 'Every item in the approved borrowing must be ready for release.';
  end if;
  select count(*) into v_assignment_count from jsonb_array_elements(p_assignments);
  if v_item_count <> v_assignment_count then raise exception 'Assign one unit to every unit-tracked item.'; end if;
  if exists (
    select 1 from jsonb_array_elements(p_assignments) x
    group by x.value ->> 'unit_id' having count(*) > 1
  ) or exists (
    select 1 from jsonb_array_elements(p_assignments) x
    group by x.value ->> 'borrowing_item_id' having count(*) > 1
  ) then raise exception 'Each borrowing item and unit must be assigned exactly once.'; end if;

  for v_assignment in
    select (x.value ->> 'borrowing_item_id')::bigint borrowing_item_id,
      (x.value ->> 'unit_id')::bigint unit_id
    from jsonb_array_elements(p_assignments) x order by (x.value ->> 'unit_id')::bigint
  loop
    if not exists (
      select 1 from public.borrowing_items bi join public.equipment e using (equipment_id)
      join public.equipment_units u on u.equipment_id = e.equipment_id
      where bi.borrowing_item_id = v_assignment.borrowing_item_id and bi.borrowing_id = p_borrowing_id
        and bi.quantity = 1 and bi.item_status = 'approved' and e.tracking_mode = 'unit'
        and u.unit_id = v_assignment.unit_id and u.status = 'available'
    ) then raise exception 'A selected unit is unknown, unavailable, or does not match the borrowing item.'; end if;
    update public.equipment_units set status = 'borrowed', updated_at = now() where unit_id = v_assignment.unit_id;
    update public.borrowing_items set unit_id = v_assignment.unit_id where borrowing_item_id = v_assignment.borrowing_item_id;
    insert into public.equipment_unit_audit (unit_id, equipment_id, actor_id, action, old_values, new_values)
    select v_assignment.unit_id, u.equipment_id, v_actor, 'released', jsonb_build_object('status', 'available'),
      jsonb_build_object('status', 'borrowed', 'borrowing_item_id', v_assignment.borrowing_item_id)
    from public.equipment_units u where u.unit_id = v_assignment.unit_id;
  end loop;

  if exists (select 1 from public.borrowing_items bi join public.equipment e using (equipment_id)
    where bi.borrowing_id = p_borrowing_id and e.tracking_mode = 'quantity') then
    raise exception 'Release mixed quantity and unit equipment through separate borrowing requests.';
  end if;
  update public.borrowing_items set item_status = 'released', released_by = v_actor, released_at = now(),
    condition_at_release = p_condition, release_photo_path = p_photo_path, issued_at = now()
  where borrowing_id = p_borrowing_id;
  update public.borrowings set transaction_status = 'released', updated_at = now() where borrowing_id = p_borrowing_id;
  update public.equipment e set availability_status = case
    when not exists (select 1 from public.equipment_units u where u.equipment_id = e.equipment_id
      and u.status = 'available') then 'borrowed'
    else 'available' end, updated_at = now()
  where e.tracking_mode = 'unit' and e.equipment_id in (
    select bi.equipment_id from public.borrowing_items bi where bi.borrowing_id = p_borrowing_id
  );
  if p_condition = 'damaged' then
    insert into public.damage_loss_reports (borrowing_item_id, reporter_id, report_type, description, photo_path)
    select bi.borrowing_item_id, v_actor, 'damage', trim(p_condition_notes), p_photo_path
    from public.borrowing_items bi where bi.borrowing_id = p_borrowing_id;
  end if;
end;
$$;
revoke all on function public.release_equipment_borrowing_units(bigint, jsonb, text, text, text) from public, anon;
grant execute on function public.release_equipment_borrowing_units(bigint, jsonb, text, text, text) to authenticated;

create or replace function public.complete_equipment_unit_return(
  p_borrowing_item_id bigint,
  p_condition text,
  p_asset_tag text default null,
  p_photo_path text default null,
  p_condition_notes text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_borrowing_id bigint;
  v_equipment_id bigint;
  v_unit_id bigint;
  v_borrowing_status text;
  v_unit_status text;
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can receive returned equipment.';
  end if;
  if nullif(trim(p_asset_tag), '') is null then raise exception 'Scan or enter the returned unit asset tag.'; end if;
  if p_condition is null or p_condition not in ('good', 'fair', 'damaged', 'lost') then raise exception 'Choose a valid return condition.'; end if;
  if not public.workflow_photo_path_is_valid(p_photo_path, v_actor) then raise exception 'The return photo path is invalid.'; end if;
  if p_condition in ('damaged', 'lost') and nullif(trim(p_condition_notes), '') is null then raise exception 'Add a damage or loss description.'; end if;
  select bi.borrowing_id, bi.equipment_id, bi.unit_id into v_borrowing_id, v_equipment_id, v_unit_id
  from public.borrowing_items bi where bi.borrowing_item_id = p_borrowing_item_id;
  if not found or v_unit_id is null then raise exception 'The borrowing item has no assigned unit.'; end if;
  perform 1 from public.equipment where equipment_id = v_equipment_id for update;
  select status into v_unit_status from public.equipment_units where unit_id = v_unit_id for update;
  select transaction_status into v_borrowing_status from public.borrowings where borrowing_id = v_borrowing_id for update;
  if v_borrowing_status <> 'released' or v_unit_status <> 'borrowed'
    or (p_asset_tag is not null and not exists (
      select 1 from public.equipment_units u where u.unit_id = v_unit_id and u.asset_tag = trim(p_asset_tag)
    )) then
    raise exception 'Only a currently released unit can be returned.';
  end if;
  if p_condition = 'damaged' then
    update public.equipment_units set status = 'maintenance', updated_at = now() where unit_id = v_unit_id;
    update public.equipment set out_of_service_quantity = out_of_service_quantity + 1, updated_at = now()
    where equipment_id = v_equipment_id;
    insert into public.unit_maintenance_log (unit_id, reason, started_at, recorded_by)
    values (v_unit_id, trim(p_condition_notes), now(), v_actor);
  elsif p_condition = 'lost' then
    update public.equipment_units set status = 'lost', updated_at = now() where unit_id = v_unit_id;
  else
    update public.equipment_units set status = 'available', updated_at = now() where unit_id = v_unit_id;
  end if;
  update public.borrowing_items set item_status = 'returned', received_by = v_actor, returned_at = now(),
    condition_at_return = p_condition, return_photo_path = p_photo_path, is_overdue = false
  where borrowing_item_id = p_borrowing_item_id and item_status = 'released';
  insert into public.equipment_unit_audit (unit_id, equipment_id, actor_id, action, old_values, new_values)
  values (v_unit_id, v_equipment_id, v_actor, 'returned', jsonb_build_object('status', v_unit_status),
    jsonb_build_object('status', case when p_condition = 'damaged' then 'maintenance' when p_condition = 'lost' then 'lost' else 'available' end,
      'condition', p_condition));
  update public.equipment e set availability_status = case
    when e.availability_status = 'retired' then 'retired'
    when e.tracking_mode = 'unit' and e.quantity = 0 then 'retired'
    when not exists (select 1 from public.equipment_units u where u.equipment_id = e.equipment_id
      and u.status in ('available', 'borrowed')) then 'maintenance'
    when not exists (select 1 from public.equipment_units u where u.equipment_id = e.equipment_id
      and u.status = 'available') then 'borrowed'
    else 'available' end, updated_at = now()
  where e.equipment_id = v_equipment_id;
  if p_condition in ('damaged', 'lost') then
    insert into public.damage_loss_reports (borrowing_item_id, reporter_id, report_type, description, photo_path)
    values (p_borrowing_item_id, v_actor, case when p_condition = 'lost' then 'loss' else 'damage' end,
      trim(p_condition_notes), p_photo_path);
  end if;
  if not exists (select 1 from public.borrowing_items where borrowing_id = v_borrowing_id and item_status = 'released') then
    update public.borrowings set transaction_status = 'returned', updated_at = now() where borrowing_id = v_borrowing_id;
    update public.return_requests set status = 'completed', completed_at = now()
    where borrowing_id = v_borrowing_id and status = 'pending';
  end if;
end;
$$;
revoke all on function public.complete_equipment_unit_return(bigint, text, text, text, text) from public, anon;
grant execute on function public.complete_equipment_unit_return(bigint, text, text, text, text) to authenticated;

create or replace function public.list_overdue_borrowings_page(
  p_page integer default 0,
  p_search text default null
)
returns table (
  borrowing_id bigint,
  borrowing_item_id bigint,
  equipment_name text,
  asset_code text,
  borrower_name text,
  borrower_email text,
  borrower_phone text,
  department text,
  expected_return_at timestamptz,
  overdue_at timestamptz,
  quantity integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can view overdue borrowers.';
  end if;
  if p_page < 0 then raise exception 'Page must be zero or greater.'; end if;
  return query select b.borrowing_id, bi.borrowing_item_id, e.equipment_name::text, e.asset_code::text,
    concat_ws(' ', br.first_name, br.middle_name, br.last_name)::text, br.email::text, u.phone::text,
    coalesce(br.department, '')::text, b.expected_return_date, bi.overdue_at, bi.quantity
  from public.borrowings b join public.borrowing_items bi using (borrowing_id)
  join public.equipment e using (equipment_id) join public.borrowers br using (borrower_id)
  left join auth.users u on u.id = br.user_id
  where b.transaction_status = 'released' and bi.item_status = 'released' and bi.is_overdue
    and (nullif(trim(p_search), '') is null or concat_ws(' ', e.equipment_name, e.asset_code,
      br.first_name, br.middle_name, br.last_name, br.email) ilike '%' || trim(p_search) || '%')
  order by b.expected_return_date, b.borrowing_id, bi.borrowing_item_id
  limit 20 offset (p_page * 20);
end;
$$;
revoke all on function public.list_overdue_borrowings_page(integer, text) from public, anon;
grant execute on function public.list_overdue_borrowings_page(integer, text) to authenticated;

create index if not exists equipment_name_asset_code_idx
  on public.equipment (equipment_name, asset_code, equipment_id) where deleted_at is null;
create index if not exists equipment_name_search_idx
  on public.equipment (lower(equipment_name) text_pattern_ops, equipment_name, equipment_id) where deleted_at is null;
create index if not exists equipment_asset_code_search_idx
  on public.equipment (lower(asset_code) text_pattern_ops, equipment_name, equipment_id) where deleted_at is null;
create index if not exists equipment_storage_location_search_idx
  on public.equipment (lower(storage_location) text_pattern_ops, equipment_name, equipment_id)
  where deleted_at is null and storage_location is not null;
create index if not exists borrowing_items_status_borrowing_idx
  on public.borrowing_items (item_status, borrowing_id, borrowing_item_id);
create index if not exists notifications_created_id_idx
  on public.notifications (created_at desc, notification_id desc);
create index if not exists notifications_title_search_idx
  on public.notifications using gin (title gin_trgm_ops);
create index if not exists notifications_message_search_idx
  on public.notifications using gin (message gin_trgm_ops);
create index if not exists equipment_audit_log_changed_id_idx
  on public.equipment_audit_log (changed_at desc, id desc);
create index if not exists equipment_audit_asset_search_idx
  on public.equipment_audit_log using gin (asset_code gin_trgm_ops);
create index if not exists borrowers_first_name_search_idx
  on public.borrowers using gin (first_name gin_trgm_ops);
create index if not exists borrowers_last_name_search_idx
  on public.borrowers using gin (last_name gin_trgm_ops);
create index if not exists borrowers_email_search_idx
  on public.borrowers using gin (email gin_trgm_ops);

notify pgrst, 'reload schema';
commit;
