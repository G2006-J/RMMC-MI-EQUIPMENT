-- Read-only preflight. Run before applying migrations to a live project.

select e.equipment_id, e.asset_code, e.quantity, e.out_of_service_quantity
from public.equipment e
where e.out_of_service_quantity < 0
   or e.out_of_service_quantity > e.quantity
order by e.equipment_id;

select r.*
from public.reservations r
where r.end_date < r.start_date
order by r.reservation_id;

select a.*
from public.borrower_agreement_acceptances a
join (
  select user_id, version_id
  from public.borrower_agreement_acceptances
  group by user_id, version_id
  having count(*) > 1
) duplicate using (user_id, version_id)
order by a.user_id, a.version_id, a.acceptance_id;

select b.*
from public.borrowers b
join (
  select user_id
  from public.borrowers
  where user_id is not null
  group by user_id
  having count(*) > 1
) duplicate using (user_id)
order by b.user_id, b.borrower_id;