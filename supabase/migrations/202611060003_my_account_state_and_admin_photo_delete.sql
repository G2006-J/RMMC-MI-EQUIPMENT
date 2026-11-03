begin;

create or replace function public.get_my_account_state()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select p.account_status
    from public.profiles p
    where p.id = (select auth.uid())
  ), 'none');
$$;
revoke all on function public.get_my_account_state() from public, anon;
grant execute on function public.get_my_account_state() to authenticated;

drop policy if exists "active administrators delete profile photos for anonymization" on storage.objects;
create policy "active administrators delete profile photos for anonymization"
  on storage.objects for delete to authenticated
  using (bucket_id = 'profile-photos' and public.is_equipment_admin_user());

notify pgrst, 'reload schema';
commit;