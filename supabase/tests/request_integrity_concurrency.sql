\set ON_ERROR_STOP on

create extension if not exists dblink;

select set_config('test.dblink_connection', :'dblink_connection', false);

create sequence public.phase4_approval_barrier_seq
  start with 1 minvalue 1;

create function public.phase4_test_approval_barrier()
returns trigger
language plpgsql
as $$
declare
  v_deadline timestamptz;
  v_arrivals bigint;
begin
  if new.transaction_status = 'approved'
    and current_setting('test.force_race', true) = 'on' then
    perform nextval('public.phase4_approval_barrier_seq');
    v_deadline := clock_timestamp() + interval '15 seconds';
    loop
      select last_value into v_arrivals from public.phase4_approval_barrier_seq;
      exit when v_arrivals >= 2;
      if clock_timestamp() >= v_deadline then
        raise exception 'Concurrency mutation barrier timed out after % arrivals.', v_arrivals;
      end if;
      perform pg_sleep(0.02);
    end loop;
  end if;
  return new;
end;
$$;
revoke all on function public.phase4_test_approval_barrier() from public, anon, authenticated;

select set_config('test.force_race', :'race_barrier', false);

do $$
begin
  if current_setting('test.force_race', true) = 'on' then
    create trigger phase4_test_approval_barrier
      before update of transaction_status on public.borrowings
      for each row execute function public.phase4_test_approval_barrier();
  end if;
end;
$$;

create temporary table phase4_concurrency_fixture (
  manager_id uuid not null,
  equipment_id bigint not null,
  borrowing_a bigint not null,
  borrowing_b bigint not null
);

create temporary table phase4_concurrency_result (
  successful_approvals integer not null,
  approved_requests integer not null,
  requested_requests integer not null
);

begin;
do $$
declare
  v_manager uuid;
  v_borrower bigint;
  v_borrower_user uuid;
  v_borrower_email text;
  v_category bigint;
  v_equipment bigint;
  v_borrowing_a bigint;
  v_borrowing_b bigint;
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

  select b.borrower_id, b.user_id, u.email
  into v_borrower, v_borrower_user, v_borrower_email
  from public.borrowers b
  join public.profiles p on p.id = b.user_id and p.account_status = 'active'
  join auth.users u on u.id = b.user_id and u.email_confirmed_at is not null
  where b.status = 'active'
    and p.role = 'staff'
  order by b.borrower_id
  limit 1;

  select category_id into v_category
  from public.categories
  order by category_id
  limit 1;

  if v_manager is null or v_borrower is null or v_category is null then
    raise exception 'Concurrency test requires an active manager, linked active borrower, and equipment category.';
  end if;

  perform set_config('request.jwt.claim.sub', v_borrower_user::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_borrower_user, 'email', v_borrower_email)::text,
    true
  );

  insert into public.equipment (
    asset_code, equipment_name, category_id, quantity, availability_status
  )
  values (
    'CONCURRENCY-' || replace(gen_random_uuid()::text, '-', ''),
    'Concurrency test equipment',
    v_category,
    1,
    'available'
  )
  returning equipment_id into v_equipment;

  insert into public.borrowings (
    transaction_code, borrower_id, purpose, destination, expected_return_date
  )
  values (
    'CONCURRENCY-A-' || replace(gen_random_uuid()::text, '-', ''),
    v_borrower, 'Concurrency test', 'Concurrency test', now() + interval '1 day'
  )
  returning borrowing_id into v_borrowing_a;

  insert into public.borrowings (
    transaction_code, borrower_id, purpose, destination, expected_return_date
  )
  values (
    'CONCURRENCY-B-' || replace(gen_random_uuid()::text, '-', ''),
    v_borrower, 'Concurrency test', 'Concurrency test', now() + interval '1 day'
  )
  returning borrowing_id into v_borrowing_b;

  insert into public.borrowing_items (borrowing_id, equipment_id, item_status, quantity)
  values
    (v_borrowing_a, v_equipment, 'requested', 1),
    (v_borrowing_b, v_equipment, 'requested', 1);

  insert into pg_temp.phase4_concurrency_fixture
    (manager_id, equipment_id, borrowing_a, borrowing_b)
  values
    (v_manager, v_equipment, v_borrowing_a, v_borrowing_b);
end;
$$;
commit;

begin;
do $$
declare
  v_fixture record;
  v_success_a integer;
  v_success_b integer;
begin
  select * into strict v_fixture from pg_temp.phase4_concurrency_fixture;

  perform dblink_connect('phase4_gate', current_setting('test.dblink_connection'));
  perform dblink_exec('phase4_gate', 'begin');
  perform equipment_id
  from dblink(
    'phase4_gate',
    format(
      'select equipment_id from public.equipment where equipment_id = %s for update',
      v_fixture.equipment_id
    ),
    false
  ) as locked_equipment(equipment_id bigint);

  perform dblink_connect('phase4_approval_a', current_setting('test.dblink_connection'));
  perform dblink_connect('phase4_approval_b', current_setting('test.dblink_connection'));

  if dblink_send_query(
    'phase4_approval_a',
    format(
      'with claim as materialized ('
      || 'select set_config(''request.jwt.claim.sub'', %L, false), '
      || 'set_config(''test.force_race'', %L, false)) '
      || 'select public.review_borrowing_request(%s, ''approve'', null) from claim',
      v_fixture.manager_id::text,
      current_setting('test.force_race', true),
      v_fixture.borrowing_a
    )
  ) <> 1 or dblink_send_query(
    'phase4_approval_b',
    format(
      'with claim as materialized ('
      || 'select set_config(''request.jwt.claim.sub'', %L, false), '
      || 'set_config(''test.force_race'', %L, false)) '
      || 'select public.review_borrowing_request(%s, ''approve'', null) from claim',
      v_fixture.manager_id::text,
      current_setting('test.force_race', true),
      v_fixture.borrowing_b
    )
  ) <> 1 then
    raise exception 'Could not start both concurrent approval calls.';
  end if;

  perform dblink_exec('phase4_gate', 'commit');

  select count(*) into v_success_a
  from dblink_get_result('phase4_approval_a', false) as result(outcome void);
  select count(*) into v_success_b
  from dblink_get_result('phase4_approval_b', false) as result(outcome void);

  perform dblink_disconnect('phase4_approval_a');
  perform dblink_disconnect('phase4_approval_b');
  perform dblink_disconnect('phase4_gate');

  insert into pg_temp.phase4_concurrency_result
    (successful_approvals, approved_requests, requested_requests)
  select
    v_success_a + v_success_b,
    count(*) filter (where transaction_status = 'approved'),
    count(*) filter (where transaction_status = 'requested')
  from public.borrowings
  where borrowing_id in (v_fixture.borrowing_a, v_fixture.borrowing_b);
end;
$$;
commit;

begin;
do $$
declare
  v_fixture record;
begin
  select * into strict v_fixture from pg_temp.phase4_concurrency_fixture;
  delete from public.borrowing_workflow_audit
  where borrowing_id in (v_fixture.borrowing_a, v_fixture.borrowing_b);
  delete from public.borrowings
  where borrowing_id in (v_fixture.borrowing_a, v_fixture.borrowing_b);
  delete from public.equipment where equipment_id = v_fixture.equipment_id;
end;
$$;
commit;

drop trigger if exists phase4_test_approval_barrier on public.borrowings;
drop function public.phase4_test_approval_barrier();
drop sequence public.phase4_approval_barrier_seq;

do $$
declare
  v_result record;
begin
  select * into strict v_result from pg_temp.phase4_concurrency_result;
  if v_result.successful_approvals <> 1
    or v_result.approved_requests <> 1
    or v_result.requested_requests <> 1 then
    raise exception 'Expected one successful approval and one remaining requested request; got % successes, % approved, % requested.',
      v_result.successful_approvals,
      v_result.approved_requests,
      v_result.requested_requests;
  end if;
  raise notice 'PASS: concurrent approvals did not oversubscribe quantity-one equipment.';
end;
$$;
