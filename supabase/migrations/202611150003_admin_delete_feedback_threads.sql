begin;

drop policy if exists "administrators delete feedback threads" on public.feedback_threads;
create policy "administrators delete feedback threads"
  on public.feedback_threads for delete to authenticated
  using (public.is_equipment_admin_user());

grant delete on public.feedback_threads to authenticated;

notify pgrst, 'reload schema';

commit;
