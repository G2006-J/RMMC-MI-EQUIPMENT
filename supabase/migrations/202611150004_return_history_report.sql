begin;

create or replace function public.get_phase7_return_history_report(
  p_start_date date,
  p_end_date date,
  p_page integer default 0,
  p_export boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_rows jsonb := '[]'::jsonb;
  v_headers jsonb := jsonb_build_array(
    'Borrowing ID',
    'Equipment',
    'Asset tag',
    'Borrower',
    'Quantity',
    'Return date (Manila)',
    'Return time (Manila)',
    'Condition upon return'
  );
  v_total integer := 0;
  v_limit integer := case when p_export then 5000 else 100 end;
  v_offset integer := case when p_export then 0 else greatest(coalesce(p_page, 0), 0) * 100 end;
begin
  if v_actor is null or not public.is_equipment_manager_user()
    or not exists (
      select 1
      from public.profiles p
      where p.id = v_actor
        and p.account_status = 'active'
        and p.role in ('admin', 'property_custodian')
    ) then
    raise exception 'Only administrators and property custodians can run reports.';
  end if;
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date
    or p_end_date - p_start_date + 1 > 366 then
    raise exception 'Choose a valid report period of 366 days or fewer.';
  end if;
  if p_page is null or p_page < 0 then
    raise exception 'Choose a valid report page.';
  end if;

  with returned_items as (
    select
      bi.borrowing_item_id,
      b.borrowing_id,
      e.equipment_name,
      coalesce(eu.asset_tag, e.asset_code, '—') as asset_tag,
      coalesce(
        nullif(trim(concat_ws(' ', br.first_name, br.middle_name, br.last_name)), ''),
        br.email,
        'Unknown borrower'
      ) as borrower_name,
      bi.quantity,
      to_char(bi.returned_at at time zone 'Asia/Manila', 'YYYY-MM-DD') as return_date,
      to_char(bi.returned_at at time zone 'Asia/Manila', 'HH12:MI AM') as return_time,
      coalesce(initcap(bi.condition_at_return), 'Not recorded') as return_condition,
      bi.returned_at
    from public.borrowing_items bi
    join public.borrowings b on b.borrowing_id = bi.borrowing_id
    join public.borrowers br on br.borrower_id = b.borrower_id
    join public.equipment e on e.equipment_id = bi.equipment_id
    left join public.equipment_units eu on eu.unit_id = bi.unit_id
    where bi.item_status = 'returned'
      and bi.returned_at >= (p_start_date::timestamp at time zone 'Asia/Manila')
      and bi.returned_at < ((p_end_date + 1)::timestamp at time zone 'Asia/Manila')
  )
  select
    (select count(*)::integer from returned_items),
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_array(
            page.borrowing_id,
            page.equipment_name,
            page.asset_tag,
            page.borrower_name,
            page.quantity,
            page.return_date,
            page.return_time,
            page.return_condition
          )
          order by page.returned_at desc, page.borrowing_item_id desc
        )
        from (
          select *
          from returned_items
          order by returned_at desc, borrowing_item_id desc
          limit v_limit offset v_offset
        ) page
      ),
      '[]'::jsonb
    )
  into v_total, v_rows;

  if p_export then
    insert into public.phase7_audit_log (
      actor_id, source, event_type, entity_type, entity_id, filters, row_count, success
    )
    values (
      v_actor,
      'rpc',
      'report_exported',
      'report',
      'return_history',
      jsonb_build_object('start_date', p_start_date, 'end_date', p_end_date),
      jsonb_array_length(v_rows),
      true
    );
  end if;

  return jsonb_build_object(
    'headers', v_headers,
    'rows', v_rows,
    'total_count', v_total,
    'page', case when p_export then 0 else p_page end,
    'page_size', v_limit,
    'truncated', p_export and v_total > 5000
  );
end;
$$;

revoke all on function public.get_phase7_return_history_report(date, date, integer, boolean) from public, anon;
grant execute on function public.get_phase7_return_history_report(date, date, integer, boolean) to authenticated;

notify pgrst, 'reload schema';

commit;
