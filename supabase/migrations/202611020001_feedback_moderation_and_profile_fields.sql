alter table public.profiles
  add column if not exists department text,
  add column if not exists course text;

alter table public.borrowers
  add column if not exists department text,
  add column if not exists course text;

drop policy if exists "administrators delete feedback replies" on public.feedback_replies;
create policy "administrators delete feedback replies"
  on public.feedback_replies for delete to authenticated
  using (public.is_equipment_admin_user());

grant delete on public.feedback_replies to authenticated;

notify pgrst, 'reload schema';
