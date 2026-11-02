alter table public.borrowings
  drop constraint if exists borrowings_transaction_status_check;

update public.borrowings
set transaction_status = case transaction_status
  when 'pending' then 'requested'
  when 'borrowed' then 'released'
  else transaction_status
end;

alter table public.borrowings
  alter column transaction_status set default 'requested',
  add constraint borrowings_transaction_status_check
    check (transaction_status in ('requested', 'approved', 'released', 'returned', 'rejected', 'cancelled'));

alter table public.borrowing_items
  drop constraint if exists borrowing_items_item_status_check;

update public.borrowing_items bi
set item_status = case
  when b.transaction_status = 'requested' then 'requested'
  when b.transaction_status = 'approved' then 'approved'
  when b.transaction_status = 'released' then 'released'
  when b.transaction_status = 'returned' then 'returned'
  else b.transaction_status
end
from public.borrowings b
where b.borrowing_id = bi.borrowing_id;

alter table public.borrowing_items
  alter column item_status set default 'requested',
  add column if not exists released_by uuid references public.profiles(id) on delete set null,
  add column if not exists released_at timestamptz,
  add column if not exists received_by uuid references public.profiles(id) on delete set null,
  add column if not exists condition_at_release text,
  add column if not exists release_photo_path text,
  add column if not exists condition_at_return text,
  add column if not exists return_photo_path text,
  add column if not exists is_overdue boolean not null default false,
  add column if not exists overdue_at timestamptz,
  add constraint borrowing_items_item_status_check
    check (item_status in ('requested', 'approved', 'released', 'returned', 'rejected', 'cancelled')),
  add constraint borrowing_items_release_condition_check
    check (condition_at_release is null or condition_at_release in ('good', 'fair', 'damaged')),
  add constraint borrowing_items_return_condition_check
    check (condition_at_return is null or condition_at_return in ('good', 'fair', 'damaged', 'lost'));

create index borrowing_items_overdue_idx
  on public.borrowing_items (overdue_at, borrowing_id)
  where is_overdue and item_status = 'released';

create table public.borrowing_workflow_audit (
  audit_id bigint generated always as identity primary key,
  borrowing_id bigint not null references public.borrowings(borrowing_id) on delete restrict,
  borrowing_item_id bigint references public.borrowing_items(borrowing_item_id) on delete restrict,
  damage_report_id bigint,
  entity_type text not null check (entity_type in ('borrowing', 'item', 'damage_report')),
  event_type text not null check (event_type in ('status_changed', 'overdue_flagged')),
  actor_id uuid references public.profiles(id) on delete set null,
  before_values jsonb,
  after_values jsonb not null,
  changed_at timestamptz not null default now()
);

create index borrowing_workflow_audit_borrowing_idx
  on public.borrowing_workflow_audit (borrowing_id, changed_at desc);
create index borrowing_workflow_audit_changed_at_idx
  on public.borrowing_workflow_audit (changed_at desc);

alter table public.borrowing_workflow_audit enable row level security;
revoke all on public.borrowing_workflow_audit from anon, authenticated;
grant select on public.borrowing_workflow_audit to authenticated;
create policy "equipment managers read borrowing workflow audit"
  on public.borrowing_workflow_audit for select to authenticated
  using (public.is_equipment_manager_user());
create policy "borrowing workflow audit is immutable"
  on public.borrowing_workflow_audit for all to public
  using (false) with check (false);

create table public.damage_loss_reports (
  report_id bigint generated always as identity primary key,
  borrowing_item_id bigint not null
    references public.borrowing_items(borrowing_item_id) on delete cascade,
  reporter_id uuid references public.profiles(id) on delete set null,
  report_type text not null check (report_type in ('damage', 'loss')),
  description text not null check (length(trim(description)) between 1 and 2000),
  photo_path text,
  resolution_status text not null default 'open'
    check (resolution_status in ('open', 'under_review', 'resolved', 'waived')),
  resolution_notes text,
  resolved_by uuid references public.profiles(id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint damage_loss_resolution_fields_check
    check (
      (resolution_status in ('open', 'under_review') and resolved_at is null)
      or (resolution_status in ('resolved', 'waived') and resolved_by is not null and resolved_at is not null)
    )
);

create index damage_loss_reports_status_created_idx
  on public.damage_loss_reports (resolution_status, created_at desc);
create index damage_loss_reports_item_created_idx
  on public.damage_loss_reports (borrowing_item_id, created_at desc);

alter table public.borrowing_workflow_audit
  add constraint borrowing_workflow_audit_damage_report_fk
    foreign key (damage_report_id) references public.damage_loss_reports(report_id) on delete restrict;

alter table public.damage_loss_reports enable row level security;
revoke all on public.damage_loss_reports from anon, authenticated;
grant select on public.damage_loss_reports to authenticated;
create policy "equipment managers read damage reports"
  on public.damage_loss_reports for select to authenticated
  using (public.is_equipment_manager_user());
create policy "borrowers read their damage reports"
  on public.damage_loss_reports for select to authenticated
  using (
    public.is_verified_active_user()
    and exists (
      select 1
      from public.borrowing_items bi
      join public.borrowings b using (borrowing_id)
      join public.borrowers br using (borrower_id)
      where bi.borrowing_item_id = damage_loss_reports.borrowing_item_id
        and br.user_id = (select auth.uid())
    )
  );
create policy "equipment managers resolve damage reports"
  on public.damage_loss_reports for update to authenticated
  using (public.is_equipment_manager_user())
  with check (public.is_equipment_manager_user());
create policy "damage reports are not directly insertable or deletable"
  on public.damage_loss_reports for all to public
  using (false) with check (false);

create or replace function public.audit_damage_loss_report_status()
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
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can change damage report status.';
  end if;
  if tg_op = 'UPDATE' and new.resolution_status is not distinct from old.resolution_status then
    return new;
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
    v_borrowing_id, new.borrowing_item_id, new.report_id, 'damage_report', 'status_changed',
    v_actor, v_before, jsonb_build_object('resolution_status', new.resolution_status)
  );
  return new;
end;
$$;
revoke all on function public.audit_damage_loss_report_status() from public, anon, authenticated;

create trigger audit_damage_loss_report_status_change
after insert or update on public.damage_loss_reports
for each row execute function public.audit_damage_loss_report_status();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'item-condition-photos',
  'item-condition-photos',
  false,
  5242880,
  array['image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "managers read item condition photos" on storage.objects;
create policy "managers read item condition photos"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'item-condition-photos'
    and public.is_equipment_manager_user()
  );
drop policy if exists "managers upload own item condition photos" on storage.objects;
create policy "managers upload own item condition photos"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'item-condition-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and public.is_equipment_manager_user()
  );
drop policy if exists "managers update own item condition photos" on storage.objects;
create policy "managers update own item condition photos"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'item-condition-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and public.is_equipment_manager_user()
  )
  with check (
    bucket_id = 'item-condition-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and public.is_equipment_manager_user()
  );
drop policy if exists "managers delete own item condition photos" on storage.objects;
create policy "managers delete own item condition photos"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'item-condition-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and public.is_equipment_manager_user()
  );

create or replace function public.audit_borrowing_workflow_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_borrowing_id bigint;
  v_borrower_user_id uuid;
  v_before jsonb;
  v_after jsonb;
  v_event text;
  v_entity text;
begin
  if tg_table_name = 'borrowings' then
    v_borrowing_id := new.borrowing_id;
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
    v_before := jsonb_build_object('status', old.transaction_status);
    v_after := jsonb_build_object('status', new.transaction_status);
    v_entity := 'borrowing';
    v_event := 'status_changed';
  else
    v_borrowing_id := new.borrowing_id;
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
    v_before := jsonb_build_object('status', old.item_status, 'is_overdue', old.is_overdue);
    v_after := jsonb_build_object('status', new.item_status, 'is_overdue', new.is_overdue);
    v_entity := 'item';
    v_event := case
      when new.is_overdue is distinct from old.is_overdue and new.item_status is not distinct from old.item_status
        then 'overdue_flagged'
      else 'status_changed'
    end;
  end if;

  insert into public.borrowing_workflow_audit (
    borrowing_id, borrowing_item_id, entity_type, event_type, actor_id, before_values, after_values
  )
  values (
    v_borrowing_id,
    case when tg_table_name = 'borrowing_items' then new.borrowing_item_id else null end,
    v_entity,
    v_event,
    v_actor,
    v_before,
    v_after
  );
  return new;
end;
$$;
revoke all on function public.audit_borrowing_workflow_status() from public, anon, authenticated;

drop trigger if exists audit_borrowing_status_change on public.borrowings;
create trigger audit_borrowing_status_change
after update of transaction_status on public.borrowings
for each row execute function public.audit_borrowing_workflow_status();
drop trigger if exists audit_borrowing_item_status_change on public.borrowing_items;
create trigger audit_borrowing_item_status_change
after update of item_status, is_overdue on public.borrowing_items
for each row execute function public.audit_borrowing_workflow_status();

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
  v_status text;
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

  select e.quantity, e.availability_status
    into v_quantity, v_status
  from public.equipment e
  where e.equipment_id = p_equipment_id and e.deleted_at is null;
  if not found or p_requested_quantity is null or p_requested_quantity < 1
    or p_start_date is null or p_end_date is null or p_end_date < p_start_date
    or v_quantity < p_requested_quantity or v_status in ('maintenance', 'retired') then
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
        and b.transaction_status in ('requested', 'approved', 'released')
        and (p_exclude_borrowing_id is null or b.borrowing_id <> p_exclude_borrowing_id)
      union all
      select r.start_date, r.end_date, r.quantity
      from public.reservations r
      where r.equipment_id = p_equipment_id
        and r.status in ('pending', 'approved')
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
    ) + p_requested_quantity > v_quantity
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
  v_status text;
begin
  if p_requested_quantity is null or p_requested_quantity < 1
    or p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    return false;
  end if;
  select e.quantity, e.availability_status into v_quantity, v_status
  from public.equipment e
  where e.equipment_id = p_equipment_id and e.deleted_at is null;
  if not found or v_quantity < p_requested_quantity or v_status in ('maintenance', 'retired') then
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
      where r.equipment_id = p_equipment_id and r.status in ('pending', 'approved')
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
    ) + p_requested_quantity > v_quantity
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
      else greatest(0, e.quantity - coalesce(occupied.amount, 0))
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
        and r.status in ('pending', 'approved')
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

create or replace function public.review_borrowing_request(
  p_borrowing_id bigint,
  p_action text,
  p_decline_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_request public.borrowings%rowtype;
  v_item record;
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can review borrowing requests.';
  end if;
  if p_action is null or p_action not in ('approve', 'reject') then
    raise exception 'Choose approve or reject.';
  end if;
  if p_action = 'reject' and nullif(trim(p_decline_reason), '') is null then
    raise exception 'A reason is required to decline a borrowing request.';
  end if;

  perform e.equipment_id
  from public.equipment e
  join public.borrowing_items bi on bi.equipment_id = e.equipment_id
  where bi.borrowing_id = p_borrowing_id
  order by e.equipment_id
  for update of e;

  select b.* into v_request
  from public.borrowings b
  where b.borrowing_id = p_borrowing_id
  for update;
  if not found or v_request.transaction_status <> 'requested' then
    raise exception 'This request is no longer awaiting review.';
  end if;

  if p_action = 'approve' then
    for v_item in
      select bi.equipment_id, bi.quantity, e.deleted_at, e.availability_status
      from public.borrowing_items bi
      join public.equipment e on e.equipment_id = bi.equipment_id
      where bi.borrowing_id = p_borrowing_id
      order by e.equipment_id
    loop
      if v_item.deleted_at is not null
        or v_item.availability_status in ('maintenance', 'retired')
        or not public.equipment_period_has_approval_capacity(
          v_item.equipment_id,
          v_request.request_date::date,
          v_request.expected_return_date::date,
          v_item.quantity,
          p_borrowing_id,
          null
        ) then
        raise exception 'The requested amount is no longer available.';
      end if;
    end loop;

    update public.borrowings
    set transaction_status = 'approved',
        approved_by = v_actor,
        approved_at = now(),
        decline_reason = null,
        updated_at = now()
    where borrowing_id = p_borrowing_id;
    update public.borrowing_items
    set item_status = 'approved'
    where borrowing_id = p_borrowing_id and item_status = 'requested';
  else
    update public.borrowings
    set transaction_status = 'rejected',
        approved_by = v_actor,
        approved_at = now(),
        decline_reason = trim(p_decline_reason),
        updated_at = now()
    where borrowing_id = p_borrowing_id;
    update public.borrowing_items
    set item_status = 'rejected'
    where borrowing_id = p_borrowing_id and item_status = 'requested';
  end if;

  update public.equipment e
  set availability_status = case
    when coalesce((
      select sum(bi.quantity)
      from public.borrowing_items bi
      join public.borrowings b using (borrowing_id)
      where bi.equipment_id = e.equipment_id
        and b.transaction_status in ('approved', 'released')
    ), 0) >= e.quantity then 'borrowed'
    else 'available'
  end
  where e.availability_status in ('available', 'borrowed')
    and e.equipment_id in (
      select bi.equipment_id from public.borrowing_items bi
      where bi.borrowing_id = p_borrowing_id
    );
end;
$$;
revoke all on function public.review_borrowing_request(bigint, text, text) from public, anon;
grant execute on function public.review_borrowing_request(bigint, text, text) to authenticated;

create or replace function public.cancel_my_pending_borrowing(p_borrowing_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_borrower bigint;
  v_status text;
begin
  if v_actor is null or not public.is_verified_active_user()
    or not exists (select 1 from public.profiles p where p.id = v_actor and p.role = 'staff') then
    raise exception 'Sign in with an active borrower account to cancel a request.';
  end if;
  v_borrower := public.current_borrower_id();
  if v_borrower is null then
    raise exception 'Your borrower account is not active.';
  end if;

  select b.transaction_status into v_status
  from public.borrowings b
  where b.borrowing_id = p_borrowing_id
    and b.borrower_id = v_borrower
  for update;
  if not found or v_status <> 'requested' then
    raise exception 'Only your requested borrowings can be cancelled.';
  end if;

  update public.borrowings
  set transaction_status = 'cancelled', updated_at = now()
  where borrowing_id = p_borrowing_id;
  update public.borrowing_items
  set item_status = 'cancelled'
  where borrowing_id = p_borrowing_id and item_status = 'requested';
end;
$$;
revoke all on function public.cancel_my_pending_borrowing(bigint) from public, anon;
grant execute on function public.cancel_my_pending_borrowing(bigint) to authenticated;

create or replace function public.request_equipment_return(p_borrowing_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_status text;
begin
  if v_actor is null or not public.is_verified_active_user()
    or not exists (select 1 from public.profiles p where p.id = v_actor and p.role = 'staff') then
    raise exception 'Sign in with an active borrower account to request a return.';
  end if;
  select b.transaction_status into v_status
  from public.borrowings b
  where b.borrowing_id = p_borrowing_id
    and b.borrower_id = public.current_borrower_id()
  for update;
  if not found or v_status <> 'released' then
    raise exception 'Only your released equipment can be returned.';
  end if;

  insert into public.return_requests (borrowing_id, requested_by)
  values (p_borrowing_id, v_actor)
  on conflict (borrowing_id) where status = 'pending' do nothing;
end;
$$;
revoke all on function public.request_equipment_return(bigint) from public, anon;
grant execute on function public.request_equipment_return(bigint) to authenticated;

create or replace function public.workflow_photo_path_is_valid(p_photo_path text, p_actor uuid)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_photo_path is null or (
    split_part(p_photo_path, '/', 1) = p_actor::text
    and split_part(p_photo_path, '/', 2) <> ''
    and split_part(p_photo_path, '/', 3) = ''
    and right(p_photo_path, 5) = '.webp'
    and length(p_photo_path) <= 160
  );
$$;
revoke all on function public.workflow_photo_path_is_valid(text, uuid) from public, anon, authenticated;

create or replace function public.release_equipment_borrowing(
  p_borrowing_id bigint,
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
  v_item_count integer;
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can release equipment.';
  end if;
  if p_condition is null or p_condition not in ('good', 'fair', 'damaged') then
    raise exception 'Choose a valid condition at release.';
  end if;
  if not public.workflow_photo_path_is_valid(p_photo_path, v_actor) then
    raise exception 'The release photo path is invalid.';
  end if;
  if p_condition = 'damaged' and nullif(trim(p_condition_notes), '') is null then
    raise exception 'Add a brief damage description before releasing a damaged item.';
  end if;

  perform e.equipment_id
  from public.equipment e
  join public.borrowing_items bi on bi.equipment_id = e.equipment_id
  where bi.borrowing_id = p_borrowing_id
  order by e.equipment_id
  for update of e;

  select b.transaction_status into v_status
  from public.borrowings b
  where b.borrowing_id = p_borrowing_id
  for update;
  if not found or v_status <> 'approved' then
    raise exception 'Only approved borrowings can be released.';
  end if;

  select count(*) into v_item_count
  from public.borrowing_items bi
  where bi.borrowing_id = p_borrowing_id and bi.item_status = 'approved';
  if v_item_count = 0 or exists (
    select 1 from public.borrowing_items bi
    where bi.borrowing_id = p_borrowing_id and bi.item_status <> 'approved'
  ) then
    raise exception 'Every item in the approved borrowing must be ready for release.';
  end if;

  update public.borrowing_items
  set item_status = 'released',
      released_by = v_actor,
      released_at = now(),
      condition_at_release = p_condition,
      release_photo_path = p_photo_path,
      issued_at = now()
  where borrowing_id = p_borrowing_id;
  update public.borrowings
  set transaction_status = 'released', updated_at = now()
  where borrowing_id = p_borrowing_id;

  if p_condition = 'damaged' then
    insert into public.damage_loss_reports (
      borrowing_item_id, reporter_id, report_type, description, photo_path
    )
    select bi.borrowing_item_id, v_actor, 'damage', trim(p_condition_notes), p_photo_path
    from public.borrowing_items bi
    where bi.borrowing_id = p_borrowing_id;
  end if;
end;
$$;
revoke all on function public.release_equipment_borrowing(bigint, text, text, text) from public, anon;
grant execute on function public.release_equipment_borrowing(bigint, text, text, text) to authenticated;

drop function if exists public.complete_equipment_return(bigint);
create function public.complete_equipment_return(
  p_borrowing_id bigint,
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
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can receive returned equipment.';
  end if;
  if p_condition is null or p_condition not in ('good', 'fair', 'damaged', 'lost') then
    raise exception 'Choose a valid condition at return.';
  end if;
  if not public.workflow_photo_path_is_valid(p_photo_path, v_actor) then
    raise exception 'The return photo path is invalid.';
  end if;
  if p_condition in ('damaged', 'lost') and nullif(trim(p_condition_notes), '') is null then
    raise exception 'Add a brief damage or loss description before receiving the item.';
  end if;

  perform e.equipment_id
  from public.equipment e
  join public.borrowing_items bi on bi.equipment_id = e.equipment_id
  where bi.borrowing_id = p_borrowing_id
  order by e.equipment_id
  for update of e;

  if not found then
    raise exception 'The borrowing equipment could not be found.';
  end if;
  perform 1
  from public.borrowings b
  where b.borrowing_id = p_borrowing_id and b.transaction_status = 'released'
  for update;
  if not found then
    raise exception 'Only released borrowings can be returned.';
  end if;
  if exists (
    select 1 from public.borrowing_items bi
    where bi.borrowing_id = p_borrowing_id and bi.item_status <> 'released'
  ) then
    raise exception 'Every item in the borrowing must be released before it can be returned.';
  end if;

  update public.borrowing_items
  set item_status = 'returned',
      received_by = v_actor,
      returned_at = now(),
      condition_at_return = p_condition,
      return_photo_path = p_photo_path,
      is_overdue = false
  where borrowing_id = p_borrowing_id;
  update public.borrowings
  set transaction_status = 'returned', updated_at = now()
  where borrowing_id = p_borrowing_id;

  if p_condition in ('damaged', 'lost') then
    insert into public.damage_loss_reports (
      borrowing_item_id, reporter_id, report_type, description, photo_path
    )
    select bi.borrowing_item_id, v_actor,
      case when p_condition = 'lost' then 'loss' else 'damage' end,
      trim(p_condition_notes),
      p_photo_path
    from public.borrowing_items bi
    where bi.borrowing_id = p_borrowing_id;
  end if;

  update public.return_requests
  set status = 'completed', completed_at = now()
  where borrowing_id = p_borrowing_id and status = 'pending';

  update public.equipment e
  set condition_status = case
        when p_condition = 'damaged' then 'damaged'
        else e.condition_status
      end,
      quantity = case
        when p_condition = 'lost' then greatest(0, e.quantity - bi.quantity)
        else e.quantity
      end,
      availability_status = case
        when e.availability_status in ('maintenance', 'retired') then e.availability_status
        when p_condition = 'damaged' then 'maintenance'
        when p_condition = 'lost' and greatest(0, e.quantity - bi.quantity) = 0 then 'retired'
        when coalesce((
          select sum(active_bi.quantity)
          from public.borrowing_items active_bi
          join public.borrowings active_b using (borrowing_id)
          where active_bi.equipment_id = e.equipment_id
            and active_b.transaction_status in ('approved', 'released')
        ), 0) >= greatest(
          0,
          e.quantity - case when p_condition = 'lost' then bi.quantity else 0 end
        ) then 'borrowed'
        else 'available'
      end
  from public.borrowing_items bi
  where bi.borrowing_id = p_borrowing_id
    and bi.equipment_id = e.equipment_id;
end;
$$;
revoke all on function public.complete_equipment_return(bigint, text, text, text) from public, anon;
grant execute on function public.complete_equipment_return(bigint, text, text, text) to authenticated;

create or replace function public.prevent_overdue_borrower_requests()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_borrower_user uuid;
begin
  if v_actor is null or not public.is_verified_active_user()
    or not exists (select 1 from public.profiles p where p.id = v_actor and p.role = 'staff') then
    raise exception 'Only verified borrower accounts can submit equipment requests.';
  end if;
  if tg_table_name = 'borrowings' then
    select br.user_id into v_borrower_user
    from public.borrowers br where br.borrower_id = new.borrower_id;
    if v_borrower_user is distinct from v_actor then
      raise exception 'Borrowing requests must belong to your linked borrower account.';
    end if;
  else
    if new.requested_by is distinct from v_actor then
      raise exception 'Reservations must belong to your signed-in account.';
    end if;
    select br.user_id into v_borrower_user
    from public.borrowers br where br.borrower_id = new.borrower_id;
    if v_borrower_user is distinct from v_actor then
      raise exception 'Reservations must belong to your linked borrower account.';
    end if;
  end if;

  if exists (
    select 1
    from public.borrowings b
    join public.borrowing_items bi using (borrowing_id)
    join public.borrowers br using (borrower_id)
    where br.user_id = v_actor
      and b.transaction_status = 'released'
      and b.expected_return_date < now()
      and bi.item_status = 'released'
  ) then
    raise exception 'You cannot submit new requests while you have overdue equipment.';
  end if;
  return new;
end;
$$;
revoke all on function public.prevent_overdue_borrower_requests() from public, anon, authenticated;

drop trigger if exists block_overdue_borrowing_requests on public.borrowings;
create trigger block_overdue_borrowing_requests
before insert on public.borrowings
for each row execute function public.prevent_overdue_borrower_requests();
drop trigger if exists block_overdue_reservation_requests on public.reservations;
create trigger block_overdue_reservation_requests
before insert on public.reservations
for each row execute function public.prevent_overdue_borrower_requests();

create or replace function public.flag_overdue_borrowing_items()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_flagged integer;
begin
  update public.borrowing_items bi
  set is_overdue = true, overdue_at = now()
  from public.borrowings b
  where b.borrowing_id = bi.borrowing_id
    and b.transaction_status = 'released'
    and b.expected_return_date < now()
    and bi.item_status = 'released'
    and not bi.is_overdue;
  get diagnostics v_flagged = row_count;
  return v_flagged;
end;
$$;
revoke all on function public.flag_overdue_borrowing_items() from public, anon, authenticated;

select public.flag_overdue_borrowing_items();

create or replace function public.list_overdue_borrowings()
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
  return query
  select b.borrowing_id, bi.borrowing_item_id, e.equipment_name::text, e.asset_code::text,
    concat_ws(' ', br.first_name, br.middle_name, br.last_name)::text,
    br.email::text, u.phone::text, coalesce(br.department, '')::text,
    b.expected_return_date, bi.overdue_at, bi.quantity
  from public.borrowings b
  join public.borrowing_items bi using (borrowing_id)
  join public.equipment e using (equipment_id)
  join public.borrowers br using (borrower_id)
  left join auth.users u on u.id = br.user_id
  where b.transaction_status = 'released'
    and bi.item_status = 'released'
    and bi.is_overdue
  order by b.expected_return_date, br.last_name, br.first_name;
end;
$$;
revoke all on function public.list_overdue_borrowings() from public, anon;
grant execute on function public.list_overdue_borrowings() to authenticated;

create or replace function public.list_damage_loss_reports()
returns table (
  report_id bigint,
  borrowing_id bigint,
  borrowing_item_id bigint,
  equipment_name text,
  asset_code text,
  borrower_name text,
  borrower_email text,
  report_type text,
  description text,
  photo_path text,
  resolution_status text,
  resolution_notes text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can review damage and loss reports.';
  end if;
  return query
  select d.report_id, b.borrowing_id, bi.borrowing_item_id, e.equipment_name::text,
    e.asset_code::text, concat_ws(' ', br.first_name, br.middle_name, br.last_name)::text,
    br.email::text, d.report_type, d.description, d.photo_path, d.resolution_status,
    d.resolution_notes, d.created_at
  from public.damage_loss_reports d
  join public.borrowing_items bi using (borrowing_item_id)
  join public.borrowings b using (borrowing_id)
  join public.equipment e using (equipment_id)
  join public.borrowers br using (borrower_id)
  order by d.created_at desc;
end;
$$;
revoke all on function public.list_damage_loss_reports() from public, anon;
grant execute on function public.list_damage_loss_reports() to authenticated;

create or replace function public.resolve_damage_loss_report(
  p_report_id bigint,
  p_resolution_status text,
  p_resolution_notes text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can resolve damage and loss reports.';
  end if;
  if p_resolution_status is null or p_resolution_status not in ('open', 'under_review', 'resolved', 'waived') then
    raise exception 'Choose a valid report resolution status.';
  end if;
  if p_resolution_status in ('resolved', 'waived')
    and nullif(trim(p_resolution_notes), '') is null then
    raise exception 'Resolution notes are required to close a damage or loss report.';
  end if;

  update public.damage_loss_reports
  set resolution_status = p_resolution_status,
      resolution_notes = nullif(trim(p_resolution_notes), ''),
      resolved_by = case when p_resolution_status in ('resolved', 'waived') then v_actor else null end,
      resolved_at = case when p_resolution_status in ('resolved', 'waived') then now() else null end,
      updated_at = now()
  where report_id = p_report_id;
  if not found then
    raise exception 'Damage or loss report not found.';
  end if;
end;
$$;
revoke all on function public.resolve_damage_loss_report(bigint, text, text) from public, anon;
grant execute on function public.resolve_damage_loss_report(bigint, text, text) to authenticated;

drop function if exists public.list_equipment_tracking_records();
create function public.list_equipment_tracking_records()
returns table (
  record_id text,
  record_type text,
  record_status text,
  borrowing_id bigint,
  reservation_id bigint,
  equipment_id bigint,
  equipment_name text,
  asset_code text,
  category_name text,
  equipment_image_url text,
  storage_location text,
  amount integer,
  total_quantity integer,
  borrower_name text,
  department text,
  destination text,
  start_date date,
  end_date date,
  pickup_at timestamptz,
  return_at timestamptz,
  profile_photo_path text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can view equipment tracking.';
  end if;

  return query
  select
    ('borrow-' || bi.borrowing_item_id::text)::text,
    'borrow'::text,
    case when bi.is_overdue then 'overdue' else 'released' end::text,
    b.borrowing_id,
    null::bigint,
    e.equipment_id,
    e.equipment_name::text,
    e.asset_code::text,
    c.category_name::text,
    e.image_url::text,
    e.storage_location::text,
    bi.quantity::integer,
    e.quantity::integer,
    concat_ws(' ', br.first_name, br.middle_name, br.last_name)::text,
    coalesce(br.department, '')::text,
    b.destination::text,
    b.request_date::date,
    b.expected_return_date::date,
    bi.released_at,
    b.expected_return_date,
    br.profile_photo_path
  from public.borrowings b
  join public.borrowers br using (borrower_id)
  join public.borrowing_items bi using (borrowing_id)
  join public.equipment e using (equipment_id)
  join public.categories c using (category_id)
  where b.transaction_status = 'released' and bi.item_status = 'released'

  union all

  select
    ('reservation-' || r.reservation_id::text)::text,
    'reservation'::text,
    'reserved'::text,
    null::bigint,
    r.reservation_id,
    e.equipment_id,
    e.equipment_name::text,
    e.asset_code::text,
    c.category_name::text,
    e.image_url::text,
    e.storage_location::text,
    r.quantity::integer,
    e.quantity::integer,
    concat_ws(' ', br.first_name, br.middle_name, br.last_name)::text,
    coalesce(br.department, '')::text,
    r.destination::text,
    r.start_date,
    r.end_date,
    (r.start_date + r.start_time) at time zone 'Asia/Manila',
    (r.end_date + r.end_time) at time zone 'Asia/Manila',
    br.profile_photo_path
  from public.reservations r
  join public.borrowers br using (borrower_id)
  join public.equipment e using (equipment_id)
  join public.categories c using (category_id)
  where r.status in ('pending', 'approved')
    and (r.end_date + r.end_time) at time zone 'Asia/Manila' >= now()
  order by 3, 17, 7;
end;
$$;
revoke all on function public.list_equipment_tracking_records() from public, anon;
grant execute on function public.list_equipment_tracking_records() to authenticated;

do $$
declare
  v_job_id bigint;
begin
  select jobid into v_job_id
  from cron.job
  where jobname = 'flag-overdue-borrowing-items';
  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;
  perform cron.schedule(
    'flag-overdue-borrowing-items',
    '0 0 * * *',
    'select public.flag_overdue_borrowing_items();'
  );
end;
$$;

notify pgrst, 'reload schema';
