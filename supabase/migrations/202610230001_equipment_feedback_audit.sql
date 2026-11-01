alter table public.equipment
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by uuid references auth.users(id) on delete set null;

create or replace function public.is_equipment_admin_user()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and p.role = 'admin'
  );
$$;

drop policy if exists "Authenticated members can read equipment" on public.equipment;
create policy "Authenticated members can read active equipment"
  on public.equipment for select to authenticated
  using (deleted_at is null);

drop policy if exists "Managers can manage equipment" on public.equipment;
create policy "Administrators can manage equipment"
  on public.equipment for all to authenticated
  using (public.is_equipment_admin_user())
  with check (public.is_equipment_admin_user());

create table if not exists public.equipment_audit_log (
  id uuid primary key default gen_random_uuid(),
  equipment_id uuid not null,
  asset_tag text not null,
  action text not null check (action in ('insert', 'update', 'delete')),
  actor_id uuid references auth.users(id) on delete set null,
  changed_fields text[] not null default '{}',
  old_values jsonb,
  new_values jsonb,
  changed_at timestamptz not null default now()
);

create index if not exists equipment_audit_log_changed_at_idx
  on public.equipment_audit_log (changed_at desc);

alter table public.equipment_audit_log enable row level security;
revoke all on public.equipment_audit_log from anon, authenticated;
grant select on public.equipment_audit_log to authenticated;

drop policy if exists "Administrators can read equipment audit log" on public.equipment_audit_log;
create policy "Administrators can read equipment audit log"
  on public.equipment_audit_log for select to authenticated
  using (public.is_equipment_admin_user());

create or replace function public.log_equipment_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old_values jsonb;
  v_new_values jsonb;
  v_changed_fields text[];
  v_action text;
begin
  if tg_op = 'INSERT' then
    v_new_values := to_jsonb(new) - 'deleted_at' - 'deleted_by';
    insert into public.equipment_audit_log (
      equipment_id, asset_tag, action, actor_id, changed_fields, new_values
    ) values (
      new.id, new.asset_tag, 'insert', (select auth.uid()),
      array['asset_tag', 'name', 'category', 'description', 'location', 'image_url', 'status'],
      v_new_values
    );
    return new;
  elsif tg_op = 'UPDATE' then
    v_old_values := to_jsonb(old) - 'deleted_at' - 'deleted_by';
    v_new_values := to_jsonb(new) - 'deleted_at' - 'deleted_by';
    select coalesce(array_agg(n.key order by n.key), '{}')
      into v_changed_fields
      from jsonb_each(v_new_values) as n
      join jsonb_each(v_old_values) as o using (key)
      where n.value is distinct from o.value;
    if old.deleted_at is null and new.deleted_at is not null then
      v_action := 'delete';
      v_changed_fields := array['deleted_at'];
    else
      v_action := 'update';
    end if;
    if cardinality(v_changed_fields) > 0 then
      insert into public.equipment_audit_log (
        equipment_id, asset_tag, action, actor_id, changed_fields, old_values, new_values
      ) values (
        new.id, new.asset_tag, v_action, (select auth.uid()),
        v_changed_fields, v_old_values, v_new_values
      );
    end if;
    return new;
  elsif tg_op = 'DELETE' then
    v_old_values := to_jsonb(old) - 'deleted_at' - 'deleted_by';
    insert into public.equipment_audit_log (
      equipment_id, asset_tag, action, actor_id, changed_fields, old_values
    ) values (
      old.id, old.asset_tag, 'delete', (select auth.uid()),
      array['asset_tag', 'name', 'category', 'description', 'location', 'image_url', 'status'],
      v_old_values
    );
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists equipment_audit_trigger on public.equipment;
create trigger equipment_audit_trigger
  after insert or update or delete on public.equipment
  for each row execute function public.log_equipment_change();

create or replace function public.delete_equipment(p_equipment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_equipment_admin_user() then
    raise exception 'Only an administrator can delete equipment.';
  end if;
  update public.equipment
  set deleted_at = now(), deleted_by = (select auth.uid())
  where id = p_equipment_id and deleted_at is null;
  if not found then
    raise exception 'Equipment was not found or has already been deleted.';
  end if;
end;
$$;

revoke all on function public.is_equipment_admin_user() from public, anon;
revoke all on function public.log_equipment_change() from public, anon, authenticated;
revoke all on function public.delete_equipment(uuid) from public, anon;
grant execute on function public.is_equipment_admin_user() to authenticated;
grant execute on function public.delete_equipment(uuid) to authenticated;

create table if not exists public.feedback_threads (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references auth.users(id) on delete cascade,
  author_name text not null,
  title text not null check (length(trim(title)) > 0 and length(title) <= 140),
  category text not null default 'suggestion' check (category in ('suggestion', 'issue', 'question', 'other')),
  message text not null check (length(trim(message)) > 0 and length(message) <= 4000),
  status text not null default 'open' check (status in ('open', 'under_review', 'planned', 'implemented')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.feedback_replies (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.feedback_threads(id) on delete cascade,
  author_id uuid not null references auth.users(id) on delete cascade,
  author_name text not null,
  message text not null check (length(trim(message)) > 0 and length(message) <= 2000),
  created_at timestamptz not null default now()
);

create index if not exists feedback_threads_created_at_idx
  on public.feedback_threads (updated_at desc);
create index if not exists feedback_replies_thread_created_idx
  on public.feedback_replies (thread_id, created_at);

alter table public.feedback_threads enable row level security;
alter table public.feedback_replies enable row level security;
revoke all on public.feedback_threads, public.feedback_replies from anon, authenticated;
grant select on public.feedback_threads, public.feedback_replies to authenticated;
grant insert (author_id, author_name, title, category, message) on public.feedback_threads to authenticated;
grant update (status) on public.feedback_threads to authenticated;
grant insert (thread_id, author_id, author_name, message) on public.feedback_replies to authenticated;

drop policy if exists "Authenticated users can read feedback threads" on public.feedback_threads;
create policy "Authenticated users can read feedback threads"
  on public.feedback_threads for select to authenticated using (true);
drop policy if exists "Authenticated users can create feedback threads" on public.feedback_threads;
create policy "Authenticated users can create feedback threads"
  on public.feedback_threads for insert to authenticated
  with check (author_id = (select auth.uid()));
drop policy if exists "Administrators can update feedback threads" on public.feedback_threads;
create policy "Administrators can update feedback threads"
  on public.feedback_threads for update to authenticated
  using (public.is_equipment_admin_user())
  with check (public.is_equipment_admin_user());

drop policy if exists "Authenticated users can read feedback replies" on public.feedback_replies;
create policy "Authenticated users can read feedback replies"
  on public.feedback_replies for select to authenticated using (true);
drop policy if exists "Authenticated users can reply to feedback" on public.feedback_replies;
create policy "Authenticated users can reply to feedback"
  on public.feedback_replies for insert to authenticated
  with check (author_id = (select auth.uid()));

create or replace function public.touch_feedback_thread()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists feedback_thread_updated_at on public.feedback_threads;
create trigger feedback_thread_updated_at
  before update on public.feedback_threads
  for each row execute function public.touch_feedback_thread();

create or replace function public.bump_feedback_thread_on_reply()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.feedback_threads
  set updated_at = now()
  where id = new.thread_id;
  return new;
end;
$$;

drop trigger if exists feedback_reply_bump_thread on public.feedback_replies;
create trigger feedback_reply_bump_thread
  after insert on public.feedback_replies
  for each row execute function public.bump_feedback_thread_on_reply();

revoke all on function public.touch_feedback_thread() from public, anon, authenticated;
revoke all on function public.bump_feedback_thread_on_reply() from public, anon, authenticated;
