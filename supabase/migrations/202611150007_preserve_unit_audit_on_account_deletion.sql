begin;

alter table public.equipment_unit_audit
  alter column actor_id drop not null,
  drop constraint if exists equipment_unit_audit_actor_id_fkey,
  add constraint equipment_unit_audit_actor_id_fkey
    foreign key (actor_id) references public.profiles(id) on delete set null;

commit;
