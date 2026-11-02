alter table public.equipment
  add column if not exists out_of_service_quantity integer not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'equipment_out_of_service_quantity_check'
      and conrelid = 'public.equipment'::regclass
  ) then
    alter table public.equipment
      add constraint equipment_out_of_service_quantity_check
      check (out_of_service_quantity >= 0 and out_of_service_quantity <= quantity);
  end if;
end;
$$;

alter table public.profiles
  alter column account_status set default 'pending';

alter table public.borrowers
  alter column status set default 'pending';

do $$
declare
  v_duplicate record;
begin
  for v_duplicate in
    select b.user_id, array_agg(b.borrower_id order by b.borrower_id) as borrower_ids
    from public.borrowers b
    where b.user_id is not null
    group by b.user_id
    having count(*) > 1
  loop
    raise notice 'Duplicate borrowers.user_id % has borrower_id values %.',
      v_duplicate.user_id, v_duplicate.borrower_ids;
  end loop;

  if exists (
    select 1
    from public.borrowers b
    where b.user_id is not null
    group by b.user_id
    having count(*) > 1
  ) then
    raise exception 'Duplicate borrowers.user_id values must be resolved before creating the unique index.';
  end if;
end;
$$;

create unique index if not exists borrowers_user_id_uidx
  on public.borrowers (user_id)
  where user_id is not null;

drop function if exists public.mark_legacy_issued_borrowings_released();

create or replace function public.preview_legacy_issued_borrowings()
returns table (
  borrowing_id bigint,
  transaction_code text,
  borrower_name text,
  borrower_email text,
  equipment_names text[],
  issued_at timestamptz,
  item_count integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can preview legacy issued equipment.';
  end if;

  return query
  select b.borrowing_id,
         b.transaction_code::text,
         concat_ws(' ', br.first_name, br.middle_name, br.last_name)::text,
         br.email::text,
         array_agg(e.equipment_name::text order by e.equipment_id),
         min(bi.issued_at),
         count(*)::integer
  from public.borrowings b
  join public.borrowers br using (borrower_id)
  join public.borrowing_items bi using (borrowing_id)
  join public.equipment e using (equipment_id)
  where b.transaction_status = 'approved'
    and bi.item_status = 'approved'
    and bi.issued_at is not null
    and not exists (
      select 1 from public.borrowing_items incomplete
      where incomplete.borrowing_id = b.borrowing_id
        and (incomplete.item_status <> 'approved' or incomplete.issued_at is null)
    )
  group by b.borrowing_id, b.transaction_code, br.first_name, br.middle_name,
           br.last_name, br.email
  order by b.borrowing_id;
end;
$$;
revoke all on function public.preview_legacy_issued_borrowings() from public, anon;
grant execute on function public.preview_legacy_issued_borrowings() to authenticated;

create or replace function public.mark_legacy_issued_borrowings_released(
  p_borrowing_ids bigint[]
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_id_count integer;
  v_eligible_count integer;
  v_equipment_id bigint;
  v_borrowing_id bigint;
  v_released integer := 0;
  v_equipment_ids bigint[] := '{}'::bigint[];
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can reconcile legacy issued equipment.';
  end if;
  if p_borrowing_ids is null or cardinality(p_borrowing_ids) = 0
    or array_position(p_borrowing_ids, null) is not null then
    raise exception 'Select one or more borrowing IDs from the preview before reconciling.';
  end if;
  select count(*), count(distinct selected.borrowing_id)
    into v_id_count, v_eligible_count
  from unnest(p_borrowing_ids) as selected(borrowing_id);
  if v_id_count <> v_eligible_count then
    raise exception 'Duplicate borrowing IDs are not allowed.';
  end if;

  select count(*) into v_eligible_count
  from public.borrowings b
  where b.borrowing_id = any(p_borrowing_ids)
    and b.transaction_status = 'approved'
    and exists (
      select 1 from public.borrowing_items bi
      where bi.borrowing_id = b.borrowing_id
        and bi.issued_at is not null
    )
    and not exists (
      select 1 from public.borrowing_items bi
      where bi.borrowing_id = b.borrowing_id
        and (bi.item_status <> 'approved' or bi.issued_at is null)
    );
  if v_eligible_count <> cardinality(p_borrowing_ids) then
    raise exception 'Every selected borrowing must still be approved and have issued timestamps on all items.';
  end if;

  for v_equipment_id in
    select e.equipment_id
    from public.equipment e
    where exists (
      select 1 from public.borrowing_items bi
      where bi.equipment_id = e.equipment_id
        and bi.borrowing_id = any(p_borrowing_ids)
    )
    order by e.equipment_id
    for update of e
  loop
    v_equipment_ids := array_append(v_equipment_ids, v_equipment_id);
  end loop;

  perform b.borrowing_id
  from public.borrowings b
  where b.borrowing_id = any(p_borrowing_ids)
  order by b.borrowing_id
  for update;

  select count(*) into v_eligible_count
  from public.borrowings b
  where b.borrowing_id = any(p_borrowing_ids)
    and b.transaction_status = 'approved'
    and exists (
      select 1 from public.borrowing_items bi
      where bi.borrowing_id = b.borrowing_id
        and bi.issued_at is not null
    )
    and not exists (
      select 1 from public.borrowing_items bi
      where bi.borrowing_id = b.borrowing_id
        and (bi.item_status <> 'approved' or bi.issued_at is null)
    );
  if v_eligible_count <> cardinality(p_borrowing_ids) then
    raise exception 'A selected borrowing changed after preview; refresh the preview before retrying.';
  end if;

  for v_borrowing_id in
    select b.borrowing_id
    from public.borrowings b
    where b.borrowing_id = any(p_borrowing_ids)
    order by b.borrowing_id
  loop
    update public.borrowing_items
    set item_status = 'released',
        released_by = v_actor,
        released_at = issued_at
    where borrowing_id = v_borrowing_id
      and item_status = 'approved'
      and issued_at is not null;

    update public.borrowings
    set transaction_status = 'released',
        updated_at = now()
    where borrowing_id = v_borrowing_id
      and transaction_status = 'approved';
    v_released := v_released + 1;
  end loop;

  update public.equipment e
  set availability_status = case
    when e.availability_status in ('maintenance', 'retired') then e.availability_status
    when e.quantity - e.out_of_service_quantity <= 0 then 'maintenance'
    when coalesce((
      select sum(bi.quantity)
      from public.borrowing_items bi
      join public.borrowings b using (borrowing_id)
      where bi.equipment_id = e.equipment_id
        and b.transaction_status in ('approved', 'released')
    ), 0) >= e.quantity - e.out_of_service_quantity then 'borrowed'
    else 'available'
  end
  where e.equipment_id = any(v_equipment_ids);

  return v_released;
end;
$$;
revoke all on function public.mark_legacy_issued_borrowings_released(bigint[]) from public, anon;
grant execute on function public.mark_legacy_issued_borrowings_released(bigint[]) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'borrowing_items_quantity_positive'
      and conrelid = 'public.borrowing_items'::regclass
  ) then
    alter table public.borrowing_items
      add constraint borrowing_items_quantity_positive check (quantity > 0);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'reservations_quantity_positive'
      and conrelid = 'public.reservations'::regclass
  ) then
    alter table public.reservations
      add constraint reservations_quantity_positive check (quantity > 0);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'reservations_end_date_gte_start_date'
      and conrelid = 'public.reservations'::regclass
  ) then
    alter table public.reservations
      add constraint reservations_end_date_gte_start_date
      check (end_date >= start_date);
  end if;
end;
$$;

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'borrowing_items'
      and column_name = 'condition_on_release'
  ) then
    execute '
      update public.borrowing_items
      set condition_at_release = coalesce(condition_at_release, condition_on_release::text)
      where condition_on_release is not null';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'borrowing_items'
      and column_name = 'condition_on_return'
  ) then
    execute '
      update public.borrowing_items
      set condition_at_return = coalesce(condition_at_return, condition_on_return::text)
      where condition_on_return is not null';
  end if;
end;
$$;

alter table public.borrowing_items
  drop column if exists condition_on_release,
  drop column if exists condition_on_return;

create or replace function public.audit_borrowing_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_borrower_user_id uuid;
begin
  if new.transaction_status is not distinct from old.transaction_status then
    return new;
  end if;

  if v_actor is not null and not public.is_equipment_manager_user() then
    select br.user_id into v_borrower_user_id
    from public.borrowers br
    where br.borrower_id = new.borrower_id;
    if not public.is_verified_active_user()
      or not exists (
        select 1 from public.profiles p
        where p.id = v_actor and p.role = 'staff'
      )
      or v_borrower_user_id is distinct from v_actor
      or new.transaction_status <> 'cancelled' then
      raise exception 'Only equipment managers or the owning borrower can change a borrowing status.';
    end if;
  elsif v_actor is null and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'A verified actor is required to change a borrowing status.';
  end if;

  insert into public.borrowing_workflow_audit (
    borrowing_id, borrowing_item_id, damage_report_id, entity_type, event_type,
    actor_id, before_values, after_values
  )
  values (
    new.borrowing_id, null, null, 'borrowing', 'status_changed',
    v_actor,
    jsonb_build_object('status', old.transaction_status),
    jsonb_build_object('status', new.transaction_status)
  );
  return new;
end;
$$;
revoke all on function public.audit_borrowing_status_change() from public, anon, authenticated;

create or replace function public.audit_borrowing_item_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_borrower_user_id uuid;
  v_event_type text;
begin
  if new.item_status is not distinct from old.item_status
    and new.is_overdue is not distinct from old.is_overdue then
    return new;
  end if;

  if v_actor is not null and not public.is_equipment_manager_user() then
    select br.user_id into v_borrower_user_id
    from public.borrowings b
    join public.borrowers br using (borrower_id)
    where b.borrowing_id = new.borrowing_id;
    if not public.is_verified_active_user()
      or not exists (
        select 1 from public.profiles p
        where p.id = v_actor and p.role = 'staff'
      )
      or v_borrower_user_id is distinct from v_actor
      or new.item_status <> 'cancelled' then
      raise exception 'Only equipment managers or the owning borrower can change a borrowing item status.';
    end if;
  elsif v_actor is null and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'A verified actor is required to change a borrowing item status.';
  end if;

  v_event_type := case
    when new.is_overdue is distinct from old.is_overdue
      and new.item_status is not distinct from old.item_status
      then 'overdue_flagged'
    else 'status_changed'
  end;
  insert into public.borrowing_workflow_audit (
    borrowing_id, borrowing_item_id, damage_report_id, entity_type, event_type,
    actor_id, before_values, after_values
  )
  values (
    new.borrowing_id, new.borrowing_item_id, null, 'item', v_event_type,
    v_actor,
    jsonb_build_object('status', old.item_status, 'is_overdue', old.is_overdue),
    jsonb_build_object('status', new.item_status, 'is_overdue', new.is_overdue)
  );
  return new;
end;
$$;
revoke all on function public.audit_borrowing_item_status_change() from public, anon, authenticated;

create or replace function public.audit_damage_loss_report_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_borrowing_id bigint;
  v_before jsonb;
begin
  if tg_op = 'UPDATE' and new.resolution_status is not distinct from old.resolution_status then
    return new;
  end if;

  if v_actor is null or not public.is_equipment_manager_user() then
    if v_actor is not null
      or session_user not in ('postgres', 'supabase_admin') then
      raise exception 'Only administrators and property custodians can change damage report status.';
    end if;
  end if;

  select bi.borrowing_id into v_borrowing_id
  from public.borrowing_items bi
  where bi.borrowing_item_id = new.borrowing_item_id;
  if not found then
    raise exception 'The borrowing item for this damage report was not found.';
  end if;

  if tg_op = 'UPDATE' then
    v_before := jsonb_build_object('resolution_status', old.resolution_status);
  end if;
  insert into public.borrowing_workflow_audit (
    borrowing_id, borrowing_item_id, damage_report_id, entity_type, event_type,
    actor_id, before_values, after_values
  )
  values (
    v_borrowing_id, new.borrowing_item_id, new.report_id,
    'damage_report', 'status_changed', v_actor, v_before,
    jsonb_build_object('resolution_status', new.resolution_status)
  );
  return new;
end;
$$;
revoke all on function public.audit_damage_loss_report_status_change() from public, anon, authenticated;

drop trigger if exists audit_borrowing_status_change on public.borrowings;
drop trigger if exists audit_borrowing_item_status_change on public.borrowing_items;
drop trigger if exists audit_damage_loss_report_status_change on public.damage_loss_reports;
drop function if exists public.audit_damage_loss_report_status();

create trigger audit_borrowing_status_change
after update of transaction_status on public.borrowings
for each row execute function public.audit_borrowing_status_change();

create trigger audit_borrowing_item_status_change
after update of item_status, is_overdue on public.borrowing_items
for each row execute function public.audit_borrowing_item_status_change();

create trigger audit_damage_loss_report_status_change
after insert or update on public.damage_loss_reports
for each row execute function public.audit_damage_loss_report_status_change();

drop function if exists public.audit_borrowing_workflow_status();

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
  v_quantity integer;
  v_out_of_service_quantity integer;
  v_status text;
  v_usable_quantity integer;
begin
  if (select auth.uid()) is null
    or not public.is_verified_active_user()
    or not exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid())
        and p.role in ('admin', 'property_custodian', 'staff')
    ) then
    return false;
  end if;

  select e.quantity, e.out_of_service_quantity, e.availability_status
    into v_quantity, v_out_of_service_quantity, v_status
  from public.equipment e
  where e.equipment_id = p_equipment_id and e.deleted_at is null;
  if not found then
    return false;
  end if;
  v_usable_quantity := v_quantity - v_out_of_service_quantity;
  if p_requested_quantity is null or p_requested_quantity < 1
    or p_start_date is null or p_end_date is null or p_end_date < p_start_date
    or v_usable_quantity < p_requested_quantity or v_status in ('maintenance', 'retired') then
    return false;
  end if;

  return not exists (
    with occupied as (
      select b.request_date::date as start_date,
             case
               when b.expected_return_date::date < current_date then 'infinity'::date
               else b.expected_return_date::date
             end as end_date,
             bi.quantity
      from public.borrowings b
      join public.borrowing_items bi using (borrowing_id)
      where bi.equipment_id = p_equipment_id
        and b.transaction_status in ('approved', 'released')
        and (p_exclude_borrowing_id is null or b.borrowing_id <> p_exclude_borrowing_id)
      union all
      select r.start_date, r.end_date, r.quantity
      from public.reservations r
      where r.equipment_id = p_equipment_id
        and r.status = 'approved'
        and (p_exclude_reservation_id is null or r.reservation_id <> p_exclude_reservation_id)
    ),
    candidate_dates as (
      select p_start_date as occupied_on
      union
      select o.start_date from occupied o
      where o.start_date > p_start_date and o.start_date <= p_end_date
    )
    select 1
    from candidate_dates d
    where (
      select coalesce(sum(o.quantity), 0)
      from occupied o
      where o.start_date <= d.occupied_on and o.end_date >= d.occupied_on
    ) + p_requested_quantity > v_usable_quantity
  );
end;
$$;
revoke all on function public.equipment_period_has_capacity(bigint, date, date, integer, bigint, bigint)
  from public, anon, authenticated;

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
set search_path = ''
as $$
declare
  v_quantity integer;
  v_out_of_service_quantity integer;
  v_status text;
  v_usable_quantity integer;
begin
  if p_requested_quantity is null or p_requested_quantity < 1
    or p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    return false;
  end if;
  select e.quantity, e.out_of_service_quantity, e.availability_status
    into v_quantity, v_out_of_service_quantity, v_status
  from public.equipment e
  where e.equipment_id = p_equipment_id and e.deleted_at is null;
  if not found then
    return false;
  end if;
  v_usable_quantity := v_quantity - v_out_of_service_quantity;
  if v_usable_quantity < p_requested_quantity or v_status in ('maintenance', 'retired') then
    return false;
  end if;

  return not exists (
    with occupied as (
      select b.request_date::date as start_date,
             case when b.expected_return_date::date < current_date then 'infinity'::date
               else b.expected_return_date::date end as end_date,
             bi.quantity
      from public.borrowings b
      join public.borrowing_items bi using (borrowing_id)
      where bi.equipment_id = p_equipment_id
        and b.transaction_status in ('approved', 'released')
        and (p_exclude_borrowing_id is null or b.borrowing_id <> p_exclude_borrowing_id)
      union all
      select r.start_date, r.end_date, r.quantity
      from public.reservations r
      where r.equipment_id = p_equipment_id
        and r.status = 'approved'
        and (p_exclude_reservation_id is null or r.reservation_id <> p_exclude_reservation_id)
    ),
    candidate_dates as (
      select p_start_date as occupied_on
      union
      select o.start_date from occupied o
      where o.start_date > p_start_date and o.start_date <= p_end_date
    )
    select 1
    from candidate_dates d
    where (
      select coalesce(sum(o.quantity), 0)
      from occupied o
      where o.start_date <= d.occupied_on and o.end_date >= d.occupied_on
    ) + p_requested_quantity > v_usable_quantity
  );
end;
$$;
revoke all on function public.equipment_period_has_approval_capacity(bigint, date, date, integer, bigint, bigint)
  from public, anon, authenticated;

create or replace function public.equipment_available_quantities()
returns table (equipment_id bigint, available_quantity integer)
language sql
stable
security definer
set search_path = ''
as $$
  select e.equipment_id,
    case
      when e.availability_status in ('maintenance', 'retired') then 0
      else greatest(
        0,
        e.quantity - e.out_of_service_quantity - coalesce(occupied.amount, 0)
      )
    end::integer
  from public.equipment e
  left join lateral (
    select sum(active.amount)::integer as amount
    from (
      select bi.quantity as amount
      from public.borrowing_items bi
      join public.borrowings b using (borrowing_id)
      where bi.equipment_id = e.equipment_id
        and b.transaction_status in ('approved', 'released')
        and b.request_date::date <= current_date
        and (
          b.transaction_status = 'released'
          or b.expected_return_date::date >= current_date
        )
      union all
      select r.quantity
      from public.reservations r
      where r.equipment_id = e.equipment_id
        and r.status = 'approved'
        and r.start_date <= current_date and r.end_date >= current_date
    ) active
  ) occupied on true
  where e.deleted_at is null
    and public.is_verified_active_user()
    and exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid())
        and p.role in ('admin', 'property_custodian', 'staff')
    );
$$;
revoke all on function public.equipment_available_quantities() from public, anon;
grant execute on function public.equipment_available_quantities() to authenticated;

notify pgrst, 'reload schema';
