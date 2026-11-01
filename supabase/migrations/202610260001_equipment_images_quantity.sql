alter table public.equipment
  add column if not exists image_url text,
  add column if not exists quantity integer not null default 1;

update public.equipment
set quantity = case when quantity is null then 1 else 0 end
where quantity is null or quantity < 0;

alter table public.equipment
  alter column quantity set default 1,
  alter column quantity set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'equipment_quantity_nonnegative'
      and conrelid = 'public.equipment'::regclass
  ) then
    alter table public.equipment
      add constraint equipment_quantity_nonnegative check (quantity >= 0);
  end if;
end;
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'equipment-images',
  'equipment-images',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "public read equipment images" on storage.objects;
create policy "public read equipment images"
  on storage.objects for select to public
  using (bucket_id = 'equipment-images');

drop policy if exists "admins upload equipment images" on storage.objects;
create policy "admins upload equipment images"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'equipment-images' and public.is_equipment_admin_user());

drop policy if exists "admins update equipment images" on storage.objects;
create policy "admins update equipment images"
  on storage.objects for update to authenticated
  using (bucket_id = 'equipment-images' and public.is_equipment_admin_user())
  with check (bucket_id = 'equipment-images' and public.is_equipment_admin_user());

drop policy if exists "admins delete equipment images" on storage.objects;
create policy "admins delete equipment images"
  on storage.objects for delete to authenticated
  using (bucket_id = 'equipment-images' and public.is_equipment_admin_user());

create or replace function public.log_equipment_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_fields text[];
  v_action text;
begin
  if tg_op = 'INSERT' then
    v_new := to_jsonb(new) - 'deleted_at' - 'deleted_by';
    insert into public.equipment_audit_log (equipment_id, asset_code, action, actor_id, changed_fields, new_values)
    values (new.equipment_id, new.asset_code, 'insert', (select auth.uid()),
      array['asset_code', 'equipment_name', 'category_id', 'brand', 'model', 'serial_number', 'description', 'storage_location', 'condition_status', 'availability_status', 'image_url', 'quantity'],
      v_new);
    return new;
  elsif tg_op = 'UPDATE' then
    v_old := to_jsonb(old) - 'deleted_at' - 'deleted_by';
    v_new := to_jsonb(new) - 'deleted_at' - 'deleted_by';
    select coalesce(array_agg(n.key order by n.key), '{}')
      into v_fields
      from jsonb_each(v_new) n
      join jsonb_each(v_old) o using (key)
      where n.value is distinct from o.value;
    if old.deleted_at is null and new.deleted_at is not null then
      v_action := 'delete';
      v_fields := array['deleted_at'];
    else
      v_action := 'update';
    end if;
    if cardinality(v_fields) > 0 then
      insert into public.equipment_audit_log (equipment_id, asset_code, action, actor_id, changed_fields, old_values, new_values)
      values (new.equipment_id, new.asset_code, v_action, (select auth.uid()), v_fields, v_old, v_new);
    end if;
    return new;
  end if;
  v_old := to_jsonb(old) - 'deleted_at' - 'deleted_by';
  insert into public.equipment_audit_log (equipment_id, asset_code, action, actor_id, changed_fields, old_values)
  values (old.equipment_id, old.asset_code, 'delete', (select auth.uid()),
    array['asset_code', 'equipment_name', 'category_id', 'brand', 'model', 'serial_number', 'description', 'storage_location', 'condition_status', 'availability_status', 'image_url', 'quantity'],
    v_old);
  return old;
end;
$$;

notify pgrst, 'reload schema';
