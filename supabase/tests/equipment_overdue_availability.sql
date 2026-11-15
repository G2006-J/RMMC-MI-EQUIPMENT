\set ON_ERROR_STOP on

begin;

do $$
declare
  v_manager uuid;
  v_staff uuid;
  v_staff_email text;
  v_borrower_id bigint;
  v_category_id bigint;
  v_equipment_id bigint;
  v_borrowing_id bigint;
  v_available_quantity integer;
begin
  select p.id
  into v_manager
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.role in ('admin', 'property_custodian')
    and p.account_status = 'active'
    and u.email_confirmed_at is not null
  order by p.created_at
  limit 1;

  select p.id, u.email, br.borrower_id
  into v_staff, v_staff_email, v_borrower_id
  from public.profiles p
  join auth.users u on u.id = p.id
  join public.borrowers br on br.user_id = p.id
  where p.role = 'staff'
    and p.account_status = 'active'
    and br.status = 'active'
    and u.email_confirmed_at is not null
  order by p.created_at
  limit 1;

  select category_id into v_category_id
  from public.categories
  order by category_id
  limit 1;

  if v_manager is null or v_staff is null or v_borrower_id is null or v_category_id is null then
    raise exception 'Test requires an active manager, linked borrower, and equipment category.';
  end if;

  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_manager)::text, true);

  insert into public.equipment (
    asset_code, equipment_name, category_id, quantity, availability_status, tracking_mode
  )
  values (
    'OVERDUE-AVAIL-' || replace(gen_random_uuid()::text, '-', ''),
    'Overdue availability test equipment',
    v_category_id,
    4,
    'available',
    'quantity'
  )
  returning equipment_id into v_equipment_id;

  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_staff, 'email', v_staff_email)::text,
    true
  );
  v_borrowing_id := public.request_equipment_borrowing(
    v_equipment_id,
    'Overdue availability test',
    'SQL test',
    now() + interval '1 day',
    4
  );

  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_manager)::text, true);
  perform public.review_borrowing_request(v_borrowing_id, 'approve', null);
  perform public.release_equipment_borrowing(v_borrowing_id, 'good', null, null);

  update public.borrowings
  set expected_return_date = now() - interval '1 day'
  where borrowing_id = v_borrowing_id;

  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);
  perform public.flag_overdue_borrowing_items();

  if not exists (
    select 1
    from public.borrowings b
    join public.borrowing_items bi using (borrowing_id)
    where b.borrowing_id = v_borrowing_id
      and b.transaction_status = 'released'
      and bi.item_status = 'released'
      and bi.quantity = 4
      and bi.is_overdue
  ) then
    raise exception 'All four units must remain released and be flagged overdue.';
  end if;

  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_staff, 'email', v_staff_email)::text,
    true
  );
  select available_quantity
  into v_available_quantity
  from public.equipment_available_quantities()
  where equipment_id = v_equipment_id;

  if v_available_quantity is distinct from 0 then
    raise exception 'Four released overdue units must leave zero units available; got %.', v_available_quantity;
  end if;
end;
$$;

rollback;

do $$
begin
  raise notice 'PASS: four released overdue units continue reducing available quantity.';
end;
$$;