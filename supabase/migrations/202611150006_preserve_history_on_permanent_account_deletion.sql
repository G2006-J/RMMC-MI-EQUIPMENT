begin;

alter table public.equipment
  drop constraint if exists equipment_deleted_by_fkey,
  add constraint equipment_deleted_by_fkey
    foreign key (deleted_by) references public.profiles(id) on delete set null;

alter table public.borrower_agreement_audit_log
  alter column actor_id drop not null,
  drop constraint if exists borrower_agreement_audit_log_actor_id_fkey,
  add constraint borrower_agreement_audit_log_actor_id_fkey
    foreign key (actor_id) references public.profiles(id) on delete set null;

alter table public.unit_maintenance_log
  alter column recorded_by drop not null,
  drop constraint if exists unit_maintenance_log_recorded_by_fkey,
  add constraint unit_maintenance_log_recorded_by_fkey
    foreign key (recorded_by) references public.profiles(id) on delete set null;

alter table public.equipment_import_audit
  alter column actor_id drop not null,
  drop constraint if exists equipment_import_audit_actor_id_fkey,
  add constraint equipment_import_audit_actor_id_fkey
    foreign key (actor_id) references public.profiles(id) on delete set null;

create or replace function public.phase7_block_equipment_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and pg_trigger_depth() > 1
    and (to_jsonb(new) - 'actor_id') = (to_jsonb(old) - 'actor_id')
    and to_jsonb(old) ->> 'actor_id' is not null
    and to_jsonb(new) ->> 'actor_id' is null
    and not exists (select 1 from public.profiles p where p.id = (to_jsonb(old) ->> 'actor_id')::uuid) then
    return new;
  end if;
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Audit history is append-only.';
  end if;
  raise exception 'Audit history is append-only.';
end; $$;

create or replace function public.phase7_block_borrowing_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and pg_trigger_depth() > 1
    and (to_jsonb(new) - 'actor_id') = (to_jsonb(old) - 'actor_id')
    and to_jsonb(old) ->> 'actor_id' is not null
    and to_jsonb(new) ->> 'actor_id' is null
    and not exists (select 1 from public.profiles p where p.id = (to_jsonb(old) ->> 'actor_id')::uuid) then
    return new;
  end if;
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Audit history is append-only.';
  end if;
  raise exception 'Audit history is append-only.';
end; $$;

create or replace function public.phase7_block_account_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and pg_trigger_depth() > 1
    and (to_jsonb(new) - 'actor_id' - 'account_id') = (to_jsonb(old) - 'actor_id' - 'account_id')
    and (
      (to_jsonb(old) ->> 'actor_id' is not null
        and to_jsonb(new) ->> 'actor_id' is null
        and not exists (select 1 from public.profiles p where p.id = (to_jsonb(old) ->> 'actor_id')::uuid))
      or (to_jsonb(old) ->> 'account_id' is not null
        and to_jsonb(new) ->> 'account_id' is null
        and not exists (select 1 from auth.users u where u.id = (to_jsonb(old) ->> 'account_id')::uuid))
    ) then
    return new;
  end if;
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Audit history is append-only.';
  end if;
  raise exception 'Audit history is append-only.';
end; $$;

create or replace function public.phase7_block_agreement_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and pg_trigger_depth() > 1
    and (to_jsonb(new) - 'actor_id') = (to_jsonb(old) - 'actor_id')
    and to_jsonb(old) ->> 'actor_id' is not null
    and to_jsonb(new) ->> 'actor_id' is null
    and not exists (select 1 from public.profiles p where p.id = (to_jsonb(old) ->> 'actor_id')::uuid) then
    return new;
  end if;
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Audit history is append-only.';
  end if;
  raise exception 'Audit history is append-only.';
end; $$;

create or replace function public.phase7_block_unit_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and pg_trigger_depth() > 1
    and (to_jsonb(new) - 'actor_id') = (to_jsonb(old) - 'actor_id')
    and to_jsonb(old) ->> 'actor_id' is not null
    and to_jsonb(new) ->> 'actor_id' is null
    and not exists (select 1 from public.profiles p where p.id = (to_jsonb(old) ->> 'actor_id')::uuid) then
    return new;
  end if;
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Audit history is append-only.';
  end if;
  raise exception 'Audit history is append-only.';
end; $$;

create or replace function public.phase7_block_import_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and pg_trigger_depth() > 1
    and (to_jsonb(new) - 'actor_id') = (to_jsonb(old) - 'actor_id')
    and to_jsonb(old) ->> 'actor_id' is not null
    and to_jsonb(new) ->> 'actor_id' is null
    and not exists (select 1 from public.profiles p where p.id = (to_jsonb(old) ->> 'actor_id')::uuid) then
    return new;
  end if;
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Audit history is append-only.';
  end if;
  raise exception 'Audit history is append-only.';
end; $$;

create or replace function public.phase7_block_canonical_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and pg_trigger_depth() > 1
    and (to_jsonb(new) - 'actor_id') = (to_jsonb(old) - 'actor_id')
    and to_jsonb(old) ->> 'actor_id' is not null
    and to_jsonb(new) ->> 'actor_id' is null
    and not exists (select 1 from public.profiles p where p.id = (to_jsonb(old) ->> 'actor_id')::uuid) then
    return new;
  end if;
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Audit history is append-only.';
  end if;
  raise exception 'Audit history is append-only.';
end; $$;

create or replace function public.phase7_block_maintenance_log()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and pg_trigger_depth() > 1
    and (to_jsonb(new) - 'recorded_by') = (to_jsonb(old) - 'recorded_by')
    and to_jsonb(old) ->> 'recorded_by' is not null
    and to_jsonb(new) ->> 'recorded_by' is null
    and not exists (select 1 from public.profiles p where p.id = (to_jsonb(old) ->> 'recorded_by')::uuid) then
    return new;
  end if;
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Maintenance history is append-only.';
  end if;
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

commit;
