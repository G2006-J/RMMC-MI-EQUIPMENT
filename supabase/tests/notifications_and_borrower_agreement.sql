\set ON_ERROR_STOP on

begin;

do $$
declare
  v_manager uuid;
  v_borrower_id bigint;
  v_borrower_user uuid;
  v_borrower_email text;
  v_pending_user uuid;
  v_category_id bigint;
  v_equipment_id bigint;
  v_agreement_id bigint;
  v_new_agreement_id bigint;
  v_borrowing_id bigint;
  v_new_borrowing_id bigint;
  v_declined_borrowing_id bigint;
  v_declined_reservation_id bigint;
  v_due_borrowing_id bigint;
  v_overdue_borrowing_id bigint;
  v_damage_borrowing_id bigint;
  v_damage_report_id bigint;
  v_reservation_id bigint;
  v_new_reservation_id bigint;
  v_manager_pending_before bigint;
  v_manager_pending_after bigint;
  v_reservation_expired_before bigint;
  v_reservation_expired_after bigint;
  v_damage_notifications_before bigint;
  v_damage_notifications_after bigint;
  v_pending_notification_id bigint;
  v_manager_notification_id bigint;
  v_own_notification_id bigint;
  v_count integer;
  v_failure text;
begin
  select p.id
  into v_manager
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.role = 'admin'
    and p.account_status = 'active'
    and u.email_confirmed_at is not null
  order by p.created_at
  limit 1;

  select b.borrower_id, b.user_id, u.email
  into v_borrower_id, v_borrower_user, v_borrower_email
  from public.borrowers b
  join public.profiles p on p.id = b.user_id
  join auth.users u on u.id = b.user_id
  where b.status = 'active'
    and p.role = 'staff'
    and p.account_status = 'active'
    and u.email_confirmed_at is not null
  order by b.borrower_id
  limit 1;

  select p.id into v_pending_user
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.email = 'ci-pending@example.com'
    and p.account_status = 'pending'
  limit 1;

  select category_id into v_category_id
  from public.categories
  order by category_id
  limit 1;

  select version_id into v_agreement_id
  from public.borrower_agreement_versions
  where active
  order by version_number desc
  limit 1;

  if v_manager is null or v_borrower_id is null or v_pending_user is null
    or v_category_id is null or v_agreement_id is null then
    raise exception 'Notification/agreement test requires admin, active borrower, pending borrower, category, and active agreement fixtures.';
  end if;
  if not exists (
    select 1 from public.borrower_agreement_versions
    where version_id = v_agreement_id
      and body_text ilike '%placeholder%'
      and body_text ilike '%loss or damage%'
      and body_text ilike '%due date%'
      and body_text ilike '%lend%'
      and body_text ilike '%school-related purposes%'
  ) then
    raise exception 'The starter agreement must be clearly marked as placeholder text and cover required borrower responsibilities.';
  end if;

  select count(*) into v_count
  from public.notifications
  where user_id = v_manager
    and notification_type = 'account_pending'
    and title = 'Borrower account waiting for review';
  if v_count <> 1 then
    raise exception 'A new pending account must create exactly one account_pending notification for the administrator; got %.', v_count;
  end if;
  if not exists (
    select 1 from cron.job
    where jobname = 'borrower-notifications-and-retention'
      and schedule = '0 1 * * *'
      and command like '%process_notification_schedule%'
  ) then
    raise exception 'The daily notification and retention job is not installed.';
  end if;

  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_manager)::text,
    true
  );
  perform public.review_borrower_access(v_pending_user, 'approve');
  if (select count(*) from public.notifications
      where user_id = v_pending_user and notification_type = 'account_approved') <> 1 then
    raise exception 'Approving an account must create exactly one notification for the correct borrower.';
  end if;

  perform set_config('request.jwt.claim.sub', v_borrower_user::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_borrower_user, 'email', v_borrower_email)::text,
    true
  );

  delete from public.borrower_agreement_acceptances
  where user_id = v_borrower_user;

  insert into public.equipment (
    asset_code, equipment_name, category_id, quantity, availability_status
  )
  values (
    'NOTIFY-AGREEMENT-' || replace(gen_random_uuid()::text, '-', ''),
    'Notification and agreement SQL test equipment',
    v_category_id,
    10,
    'available'
  )
  returning equipment_id into v_equipment_id;

  begin
    perform public.request_equipment_borrowing(
      v_equipment_id, 'Agreement test', 'Test room', now() + interval '2 days', 1
    );
    raise exception 'Borrowing request succeeded without agreement acceptance.';
  exception when others then
    get stacked diagnostics v_failure = message_text;
    if v_failure not like '%current borrower agreement%' then
      raise exception 'Borrowing request failed for the wrong reason: %', v_failure;
    end if;
  end;
  begin
    perform public.request_equipment_reservation(
      v_equipment_id, 'Agreement test', 'Test room',
      current_date + 14, current_date + 14, 1, time '09:00', time '17:00'
    );
    raise exception 'Reservation request succeeded without agreement acceptance.';
  exception when others then
    get stacked diagnostics v_failure = message_text;
    if v_failure not like '%current borrower agreement%' then
      raise exception 'Reservation request failed for the wrong reason: %', v_failure;
    end if;
  end;

  perform public.accept_borrower_agreement(v_agreement_id);
  perform public.accept_borrower_agreement(v_agreement_id);
  select count(*) into v_count
  from public.borrower_agreement_acceptances
  where user_id = v_borrower_user and version_id = v_agreement_id;
  if v_count <> 1 then
    raise exception 'Accepting the same agreement twice must create one acceptance row; got %.', v_count;
  end if;

  select count(*) into v_manager_pending_before
  from public.notifications
  where user_id = v_manager and title = 'Reservation request waiting for review';
  v_borrowing_id := public.request_equipment_borrowing(
    v_equipment_id, 'Approved notification test', 'Test room', now() + interval '2 days', 1
  );
  v_declined_borrowing_id := public.request_equipment_borrowing(
    v_equipment_id, 'Declined notification test', 'Test room', now() + interval '2 days', 1
  );
  v_reservation_id := public.request_equipment_reservation(
    v_equipment_id, 'Expired reservation notification test', 'Test room',
    current_date + 14, current_date + 14, 1, time '09:00', time '17:00'
  );
  select count(*) into v_manager_pending_after
  from public.notifications
  where user_id = v_manager and title = 'Reservation request waiting for review';
  if v_manager_pending_after - v_manager_pending_before <> 1 then
    raise exception 'A new reservation must create exactly one staff notification; got delta %.',
      v_manager_pending_after - v_manager_pending_before;
  end if;

  if (select count(*) from public.notifications
      where user_id = v_manager and borrowing_id = v_borrowing_id
        and notification_type = 'request_pending') <> 1 then
    raise exception 'A new borrowing must create exactly one staff notification.';
  end if;

  begin
    perform public.publish_borrower_agreement('Forbidden version', 'Not an administrator.');
    raise exception 'A borrower was able to publish an agreement.';
  exception when others then
    get stacked diagnostics v_failure = message_text;
    if v_failure not like '%Only an active administrator%' then
      raise exception 'Non-admin publishing failed for the wrong reason: %', v_failure;
    end if;
  end;

  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_manager)::text, true);
  v_new_agreement_id := public.publish_borrower_agreement(
    'SQL test agreement version',
    'Test agreement text for loss, return deadlines, no lending, and school purposes.'
  );
  if not exists (
    select 1 from public.borrower_agreement_audit_log
    where version_id = v_new_agreement_id and actor_id = v_manager and action = 'published'
  ) then
    raise exception 'Publishing a version must create an administrator audit entry.';
  end if;
  begin
    update public.borrower_agreement_versions
    set body_text = 'Tampered agreement text'
    where version_id = v_new_agreement_id;
    raise exception 'A published agreement body was changed.';
  exception when others then
    get stacked diagnostics v_failure = message_text;
    if v_failure not like '%immutable%' then
      raise exception 'Agreement immutability check failed for the wrong reason: %', v_failure;
    end if;
  end;
  if (select body_text from public.borrower_agreement_versions
      where version_id = v_new_agreement_id)
      <> 'Test agreement text for loss, return deadlines, no lending, and school purposes.' then
    raise exception 'The published agreement text changed.';
  end if;

  perform set_config('request.jwt.claim.sub', v_borrower_user::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_borrower_user, 'email', v_borrower_email)::text,
    true
  );
  begin
    perform public.accept_borrower_agreement(v_agreement_id);
    raise exception 'An inactive agreement version was accepted.';
  exception when others then
    get stacked diagnostics v_failure = message_text;
    if v_failure not like '%no longer active%' then
      raise exception 'Inactive agreement acceptance failed for the wrong reason: %', v_failure;
    end if;
  end;
  begin
    perform public.request_equipment_borrowing(
      v_equipment_id, 'New agreement test', 'Test room', now() + interval '2 days', 1
    );
    raise exception 'Borrowing request succeeded without accepting the newly published agreement.';
  exception when others then
    get stacked diagnostics v_failure = message_text;
    if v_failure not like '%current borrower agreement%' then
      raise exception 'New-version borrowing request failed for the wrong reason: %', v_failure;
    end if;
  end;
  begin
    perform public.request_equipment_reservation(
      v_equipment_id, 'New agreement test', 'Test room',
      current_date + 21, current_date + 21, 1, time '09:00', time '17:00'
    );
    raise exception 'Reservation request succeeded without accepting the newly published agreement.';
  exception when others then
    get stacked diagnostics v_failure = message_text;
    if v_failure not like '%current borrower agreement%' then
      raise exception 'New-version reservation request failed for the wrong reason: %', v_failure;
    end if;
  end;
  perform public.accept_borrower_agreement(v_new_agreement_id);
  perform public.accept_borrower_agreement(v_new_agreement_id);
  select count(*) into v_count
  from public.borrower_agreement_acceptances
  where user_id = v_borrower_user and version_id = v_new_agreement_id;
  if v_count <> 1 then
    raise exception 'Repeated acceptance of the new version must be idempotent.';
  end if;
  v_new_reservation_id := public.request_equipment_reservation(
    v_equipment_id, 'Accepted new agreement test', 'Test room',
    current_date + 21, current_date + 21, 1, time '09:00', time '17:00'
  );
  if v_new_reservation_id is null then
    raise exception 'A borrower who accepted the current version could not submit a reservation.';
  end if;
  v_new_borrowing_id := public.request_equipment_borrowing(
    v_equipment_id, 'Accepted new agreement test', 'Test room', now() + interval '2 days', 1
  );
  if v_new_borrowing_id is null then
    raise exception 'A borrower who accepted the current version could not submit a borrowing request.';
  end if;
  v_declined_reservation_id := public.request_equipment_reservation(
    v_equipment_id, 'Declined reservation test', 'Test room',
    current_date + 22, current_date + 22, 1, time '09:00', time '17:00'
  );

  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_manager)::text, true);
  perform public.review_borrowing_request(v_borrowing_id, 'approve');
  perform public.review_borrowing_request(v_declined_borrowing_id, 'reject', 'Equipment is needed for an exam.');
  perform public.review_equipment_reservation(v_new_reservation_id, 'approve');
  perform public.review_equipment_reservation(
    v_declined_reservation_id, 'reject', 'The room is already booked.'
  );
  perform public.review_equipment_reservation(v_reservation_id, 'approve');
  if not exists (
    select 1 from public.notifications
    where user_id = v_borrower_user and borrowing_id = v_borrowing_id
      and notification_type = 'request_approved'
  ) or (select count(*) from public.notifications
        where user_id = v_borrower_user and borrowing_id = v_borrowing_id
          and notification_type = 'request_approved') <> 1 then
    raise exception 'Approving a borrowing must notify its borrower.';
  end if;
  if not exists (
    select 1 from public.notifications
    where user_id = v_borrower_user and borrowing_id = v_declined_borrowing_id
      and notification_type = 'request_declined'
      and message like '%Equipment is needed for an exam.%'
  ) or (select count(*) from public.notifications
        where user_id = v_borrower_user and borrowing_id = v_declined_borrowing_id
          and notification_type = 'request_declined') <> 1 then
    raise exception 'Declining a borrowing must notify its borrower with the decline reason.';
  end if;
  if (select count(*) from public.notifications
      where user_id = v_borrower_user and borrowing_id is null
        and title = 'Reservation request approved'
        and notification_type = 'request_approved') <> 2
    or (select count(*) from public.notifications
        where user_id = v_borrower_user and borrowing_id is null
          and title = 'Reservation request declined'
          and notification_type = 'request_declined'
          and message like '%The room is already booked.%') <> 1 then
    raise exception 'Reservation approval and decline must notify the requester exactly once, including the decline reason.';
  end if;
  select count(*) into v_reservation_expired_before
  from public.notifications
  where user_id = v_borrower_user and notification_type = 'reservation_expired';
  update public.reservations set status = 'expired'
  where reservation_id = v_reservation_id;
  select count(*) into v_reservation_expired_after
  from public.notifications
  where user_id = v_borrower_user and notification_type = 'reservation_expired';
  if v_reservation_expired_after - v_reservation_expired_before <> 1 then
    raise exception 'An expired reservation must notify its borrower exactly once.';
  end if;

  perform public.release_equipment_borrowing(v_borrowing_id, 'good');
  perform set_config('request.jwt.claim.sub', v_borrower_user::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_borrower_user, 'email', v_borrower_email)::text,
    true
  );
  perform public.request_equipment_return(v_borrowing_id);
  if (select count(*) from public.notifications
      where user_id = v_manager and borrowing_id = v_borrowing_id
        and notification_type = 'return_pending') <> 1 then
    raise exception 'A new return request must create exactly one staff notification.';
  end if;

  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_manager)::text, true);
  perform public.complete_equipment_return(v_borrowing_id, 'good');
  if not exists (
    select 1 from public.notifications
    where user_id = v_borrower_user and borrowing_id = v_borrowing_id
      and notification_type = 'item_released'
  ) or not exists (
    select 1 from public.notifications
    where user_id = v_borrower_user and borrowing_id = v_borrowing_id
      and notification_type = 'return_confirmed'
  ) then
    raise exception 'Release and return status changes must notify the borrower.';
  end if;
  if (select count(*) from public.notifications
      where user_id = v_borrower_user and borrowing_id = v_borrowing_id
        and notification_type = 'item_released') <> 1
    or (select count(*) from public.notifications
        where user_id = v_borrower_user and borrowing_id = v_borrowing_id
          and notification_type = 'return_confirmed') <> 1 then
    raise exception 'Release and return must each create exactly one borrower notification.';
  end if;

  perform set_config('request.jwt.claim.sub', v_borrower_user::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_borrower_user, 'email', v_borrower_email)::text,
    true
  );
  v_damage_borrowing_id := public.request_equipment_borrowing(
    v_equipment_id, 'Damage report notification test', 'Test room', now() + interval '2 days', 1
  );
  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_manager)::text, true);
  perform public.review_borrowing_request(v_damage_borrowing_id, 'approve');
  perform public.release_equipment_borrowing(v_damage_borrowing_id, 'good');
  perform set_config('request.jwt.claim.sub', v_borrower_user::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_borrower_user, 'email', v_borrower_email)::text,
    true
  );
  perform public.request_equipment_return(v_damage_borrowing_id);
  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_manager)::text, true);
  select count(*) into v_damage_notifications_before
  from public.notifications
  where user_id = v_borrower_user and borrowing_id = v_damage_borrowing_id
    and notification_type = 'damage_report_updated';
  perform public.complete_equipment_return(
    v_damage_borrowing_id, 'damaged', null, 'A cracked housing was found.'
  );
  select report_id into v_damage_report_id
  from public.damage_loss_reports
  where borrowing_item_id = (
    select borrowing_item_id from public.borrowing_items
    where borrowing_id = v_damage_borrowing_id
    limit 1
  );
  select count(*) into v_damage_notifications_after
  from public.notifications
  where user_id = v_borrower_user and borrowing_id = v_damage_borrowing_id
    and notification_type = 'damage_report_updated';
  if v_damage_report_id is null
    or v_damage_notifications_after - v_damage_notifications_before <> 1 then
    raise exception 'Creating a damage report must create exactly one notification for its borrower.';
  end if;
  update public.damage_loss_reports
  set resolution_status = 'under_review'
  where report_id = v_damage_report_id;
  select count(*) into v_damage_notifications_after
  from public.notifications
  where user_id = v_borrower_user and borrowing_id = v_damage_borrowing_id
    and notification_type = 'damage_report_updated';
  if v_damage_notifications_after - v_damage_notifications_before <> 2 then
    raise exception 'Changing a damage report status must create exactly one additional notification.';
  end if;

  v_due_borrowing_id := public.request_equipment_borrowing(
    v_equipment_id, 'Due soon notification test', 'Test room', now() + interval '12 hours', 1
  );
  v_overdue_borrowing_id := public.request_equipment_borrowing(
    v_equipment_id, 'Overdue notification test', 'Test room', now() + interval '2 days', 1
  );
  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_manager)::text, true);
  perform public.review_borrowing_request(v_due_borrowing_id, 'approve');
  perform public.review_borrowing_request(v_overdue_borrowing_id, 'approve');
  perform public.release_equipment_borrowing(v_due_borrowing_id, 'good');
  perform public.release_equipment_borrowing(v_overdue_borrowing_id, 'good');
  update public.borrowings
  set expected_return_date = now() - interval '1 hour'
  where borrowing_id = v_overdue_borrowing_id;

  perform public.process_notification_schedule();
  perform public.process_notification_schedule();
  if (select count(*) from public.notifications
      where user_id = v_borrower_user and borrowing_id = v_due_borrowing_id
        and notification_type = 'due_soon') <> 1 then
    raise exception 'Two scheduler runs must create exactly one due_soon notification.';
  end if;
  if (select count(*) from public.notifications
      where user_id = v_borrower_user and borrowing_id = v_overdue_borrowing_id
        and notification_type = 'item_overdue') <> 1 then
    raise exception 'Two scheduler runs must create exactly one item_overdue notification.';
  end if;

  insert into public.notifications (
    user_id, title, message, notification_type, is_read, created_at
  )
  values (
    v_borrower_user, 'Expired read notification', 'Retention fixture.',
    'retention_test', true, now() - interval '91 days'
  );
  perform public.process_notification_schedule();
  if exists (
    select 1 from public.notifications
    where user_id = v_borrower_user and notification_type = 'retention_test'
  ) then
    raise exception 'The scheduled retention function must remove read notifications older than 90 days.';
  end if;

  select notification_id into v_manager_notification_id
  from public.notifications
  where user_id = v_manager and borrowing_id = v_borrowing_id
    and notification_type = 'request_pending'
  limit 1;
  select notification_id into v_own_notification_id
  from public.notifications
  where user_id = v_borrower_user and borrowing_id = v_borrowing_id
    and notification_type = 'request_approved'
  limit 1;
  if v_manager_notification_id is null or v_own_notification_id is null then
    raise exception 'Could not find own and staff notification rows for RLS tests.';
  end if;

  perform set_config('request.jwt.claim.sub', v_borrower_user::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_borrower_user, 'email', v_borrower_email)::text,
    true
  );
  perform set_config('test.manager_notification_id', v_manager_notification_id::text, true);
  perform set_config('test.own_notification_id', v_own_notification_id::text, true);

  if has_function_privilege('anon', 'public.mark_notification_read(bigint)', 'execute')
    or has_function_privilege('anon', 'public.mark_all_notifications_read()', 'execute')
    or exists (
      select 1 from pg_proc p, lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.oid = 'public.mark_notification_read(bigint)'::regprocedure
        and a.grantee = 0 and a.privilege_type = 'EXECUTE'
    )
    or exists (
      select 1 from pg_proc p, lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.oid = 'public.mark_all_notifications_read()'::regprocedure
        and a.grantee = 0 and a.privilege_type = 'EXECUTE'
    ) then
    raise exception 'Notification read RPCs must not be executable by anon or public.';
  end if;

  update public.profiles set account_status = 'pending' where id = v_pending_user;
  update public.borrowers set status = 'pending' where user_id = v_pending_user;
  perform set_config('request.jwt.claim.sub', v_manager::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_manager)::text, true);
  perform public.review_borrower_access(v_pending_user, 'reject');
  if (select count(*) from public.notifications
      where user_id = v_pending_user and notification_type = 'account_rejected') <> 1 then
    raise exception 'Rejecting an account must create exactly one notification for the correct borrower.';
  end if;
  select notification_id into v_pending_notification_id
  from public.notifications
  where user_id = v_pending_user and notification_type = 'account_rejected';
  perform set_config('test.pending_notification_id', v_pending_notification_id::text, true);
  perform set_config('test.pending_user_id', v_pending_user::text, true);
  perform set_config('request.jwt.claim.sub', v_borrower_user::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_borrower_user, 'email', v_borrower_email)::text,
    true
  );
end;
$$;

set local role authenticated;
do $$
declare
  v_manager_notification_id bigint := current_setting('test.manager_notification_id')::bigint;
  v_own_notification_id bigint := current_setting('test.own_notification_id')::bigint;
  v_denied boolean;
  v_marked integer;
begin
  if exists (
    select 1 from public.notifications
    where notification_id = v_manager_notification_id
  ) then
    raise exception 'A borrower can read another user''s notification.';
  end if;
  if not exists (
    select 1 from public.notifications
    where notification_id = v_own_notification_id
  ) then
    raise exception 'A borrower cannot read their own notification.';
  end if;

  v_denied := false;
  begin
    insert into public.notifications (user_id, title, message, notification_type)
    values (auth.uid(), 'Forged', 'Must not be inserted by a client.', 'forged');
  exception when insufficient_privilege then
    v_denied := true;
  end;
  if not v_denied then
    raise exception 'A client can insert notifications.';
  end if;

  v_denied := false;
  begin
    update public.notifications set title = 'Forged title'
    where notification_id = v_own_notification_id;
  exception when insufficient_privilege then
    v_denied := true;
  end;
  if not v_denied then
    raise exception 'A client can update notification columns directly.';
  end if;

  v_denied := false;
  begin
    delete from public.notifications where notification_id = v_own_notification_id;
  exception when insufficient_privilege then
    v_denied := true;
  end;
  if not v_denied then
    raise exception 'A client can delete notifications.';
  end if;

  v_denied := false;
  begin
    perform public.mark_notification_read(v_manager_notification_id);
  exception when others then
    v_denied := sqlerrm = 'Notification not found.';
  end;
  if not v_denied then
    raise exception 'A borrower can mark another user''s notification as read.';
  end if;
  perform public.mark_notification_read(v_own_notification_id);
  if not exists (
    select 1 from public.notifications
    where notification_id = v_own_notification_id and is_read
  ) then
    raise exception 'The mark-read RPC did not update the caller''s own notification.';
  end if;

  v_marked := public.mark_all_notifications_read();
  if exists (
    select 1 from public.notifications where user_id = auth.uid() and not is_read
  ) then
    raise exception 'The mark-all-read RPC did not mark all caller-owned notifications.';
  end if;

  perform set_config(
    'request.jwt.claim.sub',
    current_setting('test.pending_user_id'),
    true
  );
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', current_setting('test.pending_user_id')::uuid)::text,
    true
  );
  perform public.mark_notification_read(current_setting('test.pending_notification_id')::bigint);
  if not exists (
    select 1 from public.notifications
    where notification_id = current_setting('test.pending_notification_id')::bigint
      and is_read
  ) then
    raise exception 'An inactive account must still be able to read and mark its own rejection notification.';
  end if;
end;
$$;
reset role;

rollback;

select 'PASS: notification isolation, event triggers, scheduler idempotency, retention, agreement acceptance, publishing, and request enforcement.' as result;
