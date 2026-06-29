-- Fix calculate_ctp_options: STD_PRIMARY threshold_compliant was hardcoded to true,
-- bypassing the configured max_cost_deviation_percentage threshold.
-- All sourcing options must respect the same cost threshold.

create or replace function public.calculate_ctp_options(
  p_customer_id text,
  p_material text,
  p_requested_quantity numeric,
  p_selling_unit_price numeric,
  p_idempotency_key text default null
) returns table (
  quote_request_id uuid,
  quote_option_id uuid,
  option_code text,
  option_label text,
  sourcing_strategy text,
  promised_delivery_date date,
  procurement_cost numeric,
  incremental_cost numeric,
  projected_margin numeric,
  threshold_compliant boolean,
  deterministic_explanation text
) language plpgsql security definer set search_path = public, auth as $$
declare
  v_actor uuid := auth.uid();
  v_start timestamptz := clock_timestamp();
  v_customer public.customers%rowtype;
  v_item public.items%rowtype;
  v_quote_id uuid;
  v_op_date date := public.get_operational_date();
  v_stock_lead integer := public.get_setting_integer('stock_fulfillment_lead_time_working_days', 2);
  v_max_delivery integer := public.get_setting_integer('max_delivery_deviation_working_days', 0);
  v_max_cost numeric := public.get_setting_decimal('max_cost_deviation_percentage', 0);
  v_free_stock numeric;
  v_primary public.contracts%rowtype;
  v_secondary public.contracts%rowtype;
  v_revenue numeric;
  v_baseline_unit numeric;
  v_baseline_cost numeric;
  v_standard_date date;
  v_stock_qty numeric;
  v_shortage numeric;
  v_plan jsonb;
  v_po record;
  v_cost jsonb;
  v_po_qty numeric;
  v_has_overdue boolean;
  v_candidate_date date;
  v_unit numeric;
  v_best uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_requested_quantity <= 0 or p_selling_unit_price <= 0 then raise exception 'INVALID_QUOTE_INPUT'; end if;

  select * into v_customer from public.customers where customer_id = p_customer_id;
  select * into v_item from public.items where material = p_material;
  if v_customer.customer_id is null or v_item.material is null then raise exception 'UNKNOWN_CUSTOMER_OR_MATERIAL'; end if;

  select * into v_primary
  from public.contracts
  where material = p_material and is_primary is true and v_op_date between validity_start and validity_end
  order by unit_price_standard nulls last
  limit 1;

  select * into v_secondary
  from public.contracts
  where material = p_material and coalesce(is_primary, false) is false and v_op_date between validity_start and validity_end
  order by unit_price_standard nulls last
  limit 1;

  v_baseline_unit := coalesce(v_primary.unit_price_standard, v_secondary.unit_price_standard, 0);
  v_revenue := p_requested_quantity * p_selling_unit_price;
  v_baseline_cost := p_requested_quantity * v_baseline_unit;
  v_standard_date := public.add_working_days(v_op_date, coalesce(v_primary.lead_time_standard_wd, v_secondary.lead_time_standard_wd, 7));

  insert into public.quote_requests (customer_id, customer_tier_snapshot, material, requested_quantity, selling_unit_price, status, idempotency_key, created_by)
  values (p_customer_id, v_customer.customer_tier, p_material, p_requested_quantity, p_selling_unit_price, 'calculating', p_idempotency_key, v_actor)
  on conflict (created_by, idempotency_key) where idempotency_key is not null
  do update set updated_at = now()
  returning id into v_quote_id;

  if exists (select 1 from public.commitments as c where c.quote_request_id = v_quote_id and c.status = 'active') then
    return query
    select qo.quote_request_id, qo.id, qo.option_code, qo.option_label, qo.sourcing_strategy, qo.promised_delivery_date,
           qo.procurement_cost, qo.incremental_cost, qo.projected_margin, qo.threshold_compliant, qo.deterministic_explanation
    from public.quote_options qo where qo.quote_request_id = v_quote_id order by qo.threshold_compliant desc, qo.promised_delivery_date, qo.procurement_cost;
    return;
  end if;

  delete from public.quote_options as qo where qo.quote_request_id = v_quote_id;

  select greatest(i.current_stock - coalesce(sa.qty, 0) - coalesce(ld.qty, 0), 0)
  into v_free_stock
  from public.items i
  left join (
    select c.material, sum(a.allocated_quantity) qty
    from public.commitment_allocations a join public.commitments c on c.id = a.commitment_id
    where c.status = 'active' and a.source_type = 'stock'
    group by c.material
  ) sa on sa.material = i.material
  left join (
    select material, sum(committed_quantity) qty
    from public.commitments
    where status = 'active' and source_type = 'legacy_history'
    group by material
  ) ld on ld.material = i.material
  where i.material = p_material;
  v_free_stock := coalesce(v_free_stock, 0);

  v_stock_qty := least(v_free_stock, p_requested_quantity);
  v_plan := case when v_stock_qty > 0
    then jsonb_build_array(jsonb_build_object('source_type','stock','quantity',v_stock_qty,'availability_date',public.add_working_days(v_op_date, v_stock_lead),'unit_cost',v_baseline_unit))
    else '[]'::jsonb end;

  if v_stock_qty >= p_requested_quantity then
    v_cost := public.calculate_option_cost(v_plan, v_revenue);
    insert into public.quote_options (
      quote_request_id, option_code, option_label, sourcing_strategy, promised_delivery_date,
      lead_time_working_days, standard_reference_lead_time_working_days, delivery_deviation_working_days,
      baseline_cost, procurement_cost, incremental_cost, cost_deviation_percentage, revenue, projected_margin,
      margin_percentage, threshold_compliant, allocation_plan, deterministic_explanation
    )
    values (
      v_quote_id, 'STOCK', 'Current stock', 'current_stock', public.add_working_days(v_op_date, v_stock_lead),
      v_stock_lead, coalesce(v_primary.lead_time_standard_wd, 7), 0,
      v_baseline_cost, (v_cost->>'procurement_cost')::numeric, (v_cost->>'procurement_cost')::numeric - v_baseline_cost,
      0, v_revenue, (v_cost->>'projected_margin')::numeric, (v_cost->>'margin_percentage')::numeric,
      true, v_plan, 'Current unallocated stock covers the complete requested quantity.'
    );

    update public.quote_requests as qr
    set calculation_completed_at = now(),
        response_time_ms = greatest(extract(milliseconds from clock_timestamp() - v_start)::integer, 1),
        status = 'pending_review',
        escalation_reason = null,
        updated_at = now()
    where qr.id = v_quote_id;

    select qo.id into v_best
    from public.quote_options as qo
    where qo.quote_request_id = v_quote_id and qo.threshold_compliant
    order by qo.promised_delivery_date, qo.procurement_cost, qo.projected_margin desc
    limit 1;

    if v_best is not null then
      begin
        perform public.confirm_quote_option(v_quote_id, v_best, 'automatic', null);
      exception when others then
        update public.quote_requests as qr
        set status = 'stale', escalation_reason = 'Automatic confirmation failed: ' || sqlerrm, updated_at = now()
        where qr.id = v_quote_id;
      end;
    end if;

    return query
    select qo.quote_request_id, qo.id, qo.option_code, qo.option_label, qo.sourcing_strategy,
           qo.promised_delivery_date, qo.procurement_cost, qo.incremental_cost, qo.projected_margin,
           qo.threshold_compliant, qo.deterministic_explanation
    from public.quote_options as qo
    where qo.quote_request_id = v_quote_id
    order by qo.threshold_compliant desc, qo.promised_delivery_date, qo.procurement_cost;
    return;
  end if;

  v_plan := case when v_stock_qty > 0
    then jsonb_build_array(jsonb_build_object('source_type','stock','quantity',v_stock_qty,'availability_date',public.add_working_days(v_op_date, v_stock_lead),'unit_cost',v_baseline_unit))
    else '[]'::jsonb end;
  v_shortage := p_requested_quantity - v_stock_qty;
  v_candidate_date := public.add_working_days(v_op_date, v_stock_lead);
  v_has_overdue := false;
  for v_po in
    select * from public.open_po_availability
    where material = p_material and unallocated_quantity > 0 and buffered_availability_date <= v_standard_date
    order by overdue, buffered_availability_date, po_id
  loop
    exit when v_shortage <= 0;
    v_po_qty := least(v_po.unallocated_quantity, v_shortage);
    v_plan := v_plan || jsonb_build_array(jsonb_build_object('source_type','open_po','source_po_id',v_po.po_id,'quantity',v_po_qty,'availability_date',v_po.buffered_availability_date,'unit_cost',coalesce(v_po.unit_cost, v_baseline_unit),'overdue',v_po.overdue));
    v_shortage := v_shortage - v_po_qty;
    v_candidate_date := greatest(v_candidate_date, v_po.buffered_availability_date);
    v_has_overdue := v_has_overdue or v_po.overdue;
  end loop;

  if v_shortage <= 0 then
    v_cost := public.calculate_option_cost(v_plan, v_revenue);
    insert into public.quote_options (
      quote_request_id, option_code, option_label, sourcing_strategy, vendor_code, promised_delivery_date,
      lead_time_working_days, standard_reference_lead_time_working_days, delivery_deviation_working_days,
      baseline_cost, procurement_cost, incremental_cost, cost_deviation_percentage, revenue, projected_margin,
      margin_percentage, threshold_compliant, allocation_plan, deterministic_explanation
    )
    values (
      v_quote_id, 'OPEN_PO', case when v_stock_qty > 0 then 'Stock plus open PO' else 'Existing open PO' end, case when v_stock_qty > 0 then 'stock_plus_open_po' else 'existing_open_po' end, v_primary.vendor_code, v_candidate_date,
      public.working_days_between(v_op_date, v_candidate_date), coalesce(v_primary.lead_time_standard_wd, 7), public.delivery_delay_working_days(v_standard_date, v_candidate_date),
      v_baseline_cost, (v_cost->>'procurement_cost')::numeric, (v_cost->>'procurement_cost')::numeric - v_baseline_cost,
      coalesce(((v_cost->>'procurement_cost')::numeric - v_baseline_cost) / nullif(v_baseline_cost, 0) * 100, 0),
      v_revenue, (v_cost->>'projected_margin')::numeric, (v_cost->>'margin_percentage')::numeric,
      not v_has_overdue and public.delivery_delay_working_days(v_standard_date, v_candidate_date) <= v_max_delivery,
      v_plan,
      case when v_has_overdue then 'Uses an overdue open purchase order and requires human verification.' when v_stock_qty > 0 then 'Current stock and usable open purchase orders cover the complete quantity.' else 'Usable open purchase orders cover the complete quantity.' end
    );
  end if;

  if v_primary.contract_id is not null then
    v_plan := case when v_stock_qty > 0 then jsonb_build_array(jsonb_build_object('source_type','stock','quantity',v_stock_qty,'availability_date',public.add_working_days(v_op_date, v_stock_lead),'unit_cost',v_baseline_unit)) else '[]'::jsonb end;
    v_shortage := p_requested_quantity - v_stock_qty;
    for v_po in
      select * from public.open_po_availability
      where material = p_material and unallocated_quantity > 0 and buffered_availability_date <= v_standard_date and not overdue
      order by buffered_availability_date, po_id
    loop
      exit when v_shortage <= 0;
      v_po_qty := least(v_po.unallocated_quantity, v_shortage);
      v_plan := v_plan || jsonb_build_array(jsonb_build_object('source_type','open_po','source_po_id',v_po.po_id,'quantity',v_po_qty,'availability_date',v_po.buffered_availability_date,'unit_cost',coalesce(v_po.unit_cost, v_primary.unit_price_standard),'overdue',false));
      v_shortage := v_shortage - v_po_qty;
    end loop;
    if v_shortage > 0 then
      v_plan := v_plan || jsonb_build_array(jsonb_build_object('source_type','new_po','quantity',v_shortage,'availability_date',v_standard_date,'unit_cost',v_primary.unit_price_standard,'vendor_code',v_primary.vendor_code,'sourcing_mode','standard'));
    end if;
    v_cost := public.calculate_option_cost(v_plan, v_revenue);
    insert into public.quote_options (
      quote_request_id, option_code, option_label, sourcing_strategy, vendor_code, promised_delivery_date,
      lead_time_working_days, standard_reference_lead_time_working_days, delivery_deviation_working_days,
      baseline_cost, procurement_cost, incremental_cost, cost_deviation_percentage, revenue, projected_margin,
      margin_percentage, requires_new_purchase_order, threshold_compliant, allocation_plan, deterministic_explanation
    )
    values (
      v_quote_id, 'STD_PRIMARY', 'Standard replenishment', 'new_standard_po', v_primary.vendor_code, v_standard_date,
      v_primary.lead_time_standard_wd, v_primary.lead_time_standard_wd, 0,
      v_baseline_cost, (v_cost->>'procurement_cost')::numeric, (v_cost->>'procurement_cost')::numeric - v_baseline_cost,
      coalesce(((v_cost->>'procurement_cost')::numeric - v_baseline_cost) / nullif(v_baseline_cost, 0) * 100, 0),
      v_revenue, (v_cost->>'projected_margin')::numeric, (v_cost->>'margin_percentage')::numeric,
      v_shortage > 0,
      coalesce(((v_cost->>'procurement_cost')::numeric - v_baseline_cost) / nullif(v_baseline_cost, 0) * 100, 0) <= v_max_cost,
      v_plan,
      'The uncovered shortage is sourced through a standard primary-vendor purchase order.'
    );
  end if;

  if v_secondary.contract_id is not null then
    v_unit := v_secondary.unit_price_standard;
    v_candidate_date := public.add_working_days(v_op_date, v_secondary.lead_time_standard_wd);
    v_plan := case when v_stock_qty > 0 then jsonb_build_array(jsonb_build_object('source_type','stock','quantity',v_stock_qty,'availability_date',public.add_working_days(v_op_date, v_stock_lead),'unit_cost',v_baseline_unit)) else '[]'::jsonb end;
    v_shortage := p_requested_quantity - v_stock_qty;
    if v_shortage > 0 then
      v_plan := v_plan || jsonb_build_array(jsonb_build_object('source_type','new_po','quantity',v_shortage,'availability_date',v_candidate_date,'unit_cost',v_unit,'vendor_code',v_secondary.vendor_code,'sourcing_mode','secondary_standard'));
    end if;
    v_cost := public.calculate_option_cost(v_plan, v_revenue);
    insert into public.quote_options (
      quote_request_id, option_code, option_label, sourcing_strategy, vendor_code, promised_delivery_date,
      lead_time_working_days, standard_reference_lead_time_working_days, delivery_deviation_working_days,
      baseline_cost, procurement_cost, incremental_cost, cost_deviation_percentage, revenue, projected_margin,
      margin_percentage, requires_new_purchase_order, threshold_compliant, allocation_plan, deterministic_explanation
    )
    values (
      v_quote_id, 'STD_SECONDARY', 'Secondary standard vendor', 'secondary_standard_vendor', v_secondary.vendor_code, v_candidate_date,
      v_secondary.lead_time_standard_wd, coalesce(v_primary.lead_time_standard_wd, v_secondary.lead_time_standard_wd), public.delivery_delay_working_days(v_standard_date, v_candidate_date),
      v_baseline_cost, (v_cost->>'procurement_cost')::numeric, (v_cost->>'procurement_cost')::numeric - v_baseline_cost,
      coalesce(((v_cost->>'procurement_cost')::numeric - v_baseline_cost) / nullif(v_baseline_cost, 0) * 100, 0),
      v_revenue, (v_cost->>'projected_margin')::numeric, (v_cost->>'margin_percentage')::numeric,
      v_shortage > 0, coalesce(((v_cost->>'procurement_cost')::numeric - v_baseline_cost) / nullif(v_baseline_cost, 0) * 100, 0) <= v_max_cost,
      v_plan, 'The uncovered shortage is sourced through a secondary standard vendor.'
    );

    if v_secondary.unit_price_expedite is not null and v_secondary.lead_time_expedite_wd is not null then
      v_unit := v_secondary.unit_price_expedite;
      v_candidate_date := public.add_working_days(v_op_date, ceil(v_secondary.lead_time_expedite_wd)::integer);
      v_plan := case when v_stock_qty > 0 then jsonb_build_array(jsonb_build_object('source_type','stock','quantity',v_stock_qty,'availability_date',public.add_working_days(v_op_date, v_stock_lead),'unit_cost',v_baseline_unit)) else '[]'::jsonb end;
      v_shortage := p_requested_quantity - v_stock_qty;
      if v_shortage > 0 then
        v_plan := v_plan || jsonb_build_array(jsonb_build_object('source_type','new_po','quantity',v_shortage,'availability_date',v_candidate_date,'unit_cost',v_unit,'vendor_code',v_secondary.vendor_code,'sourcing_mode','fast_track'));
      end if;
      v_cost := public.calculate_option_cost(v_plan, v_revenue);
      insert into public.quote_options (
        quote_request_id, option_code, option_label, sourcing_strategy, vendor_code, promised_delivery_date,
        lead_time_working_days, standard_reference_lead_time_working_days, delivery_deviation_working_days,
        baseline_cost, procurement_cost, incremental_cost, cost_deviation_percentage, revenue, projected_margin,
        margin_percentage, is_expedited, requires_new_purchase_order, threshold_compliant, allocation_plan, deterministic_explanation
      )
      values (
        v_quote_id, 'FAST_TRACK', 'Fast-track shortage sourcing', 'fast_track', v_secondary.vendor_code, v_candidate_date,
        ceil(v_secondary.lead_time_expedite_wd)::integer, coalesce(v_primary.lead_time_standard_wd, v_secondary.lead_time_standard_wd), 0,
        v_baseline_cost, (v_cost->>'procurement_cost')::numeric, (v_cost->>'procurement_cost')::numeric - v_baseline_cost,
        coalesce(((v_cost->>'procurement_cost')::numeric - v_baseline_cost) / nullif(v_baseline_cost, 0) * 100, 0),
        v_revenue, (v_cost->>'projected_margin')::numeric, (v_cost->>'margin_percentage')::numeric,
        true, v_shortage > 0, coalesce(((v_cost->>'procurement_cost')::numeric - v_baseline_cost) / nullif(v_baseline_cost, 0) * 100, 0) <= v_max_cost,
        v_plan, 'The uncovered shortage is sourced using the expedited vendor price and lead time.'
      );
    end if;
  end if;

  if v_primary.contract_id is not null and v_primary.unit_price_expedite is null and v_primary.expedite_freight_cost is not null and v_primary.lead_time_expedite_wd is not null then
    v_unit := v_primary.unit_price_standard + v_primary.expedite_freight_cost;
    v_candidate_date := public.add_working_days(v_op_date, ceil(v_primary.lead_time_expedite_wd)::integer);
    v_plan := case when v_stock_qty > 0 then jsonb_build_array(jsonb_build_object('source_type','stock','quantity',v_stock_qty,'availability_date',public.add_working_days(v_op_date, v_stock_lead),'unit_cost',v_baseline_unit)) else '[]'::jsonb end;
    v_shortage := p_requested_quantity - v_stock_qty;
    if v_shortage > 0 then
      v_plan := v_plan || jsonb_build_array(jsonb_build_object('source_type','new_po','quantity',v_shortage,'availability_date',v_candidate_date,'unit_cost',v_unit,'vendor_code',v_primary.vendor_code,'sourcing_mode','air_freight','freight_cost_per_unit',v_primary.expedite_freight_cost));
    end if;
    v_cost := public.calculate_option_cost(v_plan, v_revenue);
    insert into public.quote_options (
      quote_request_id, option_code, option_label, sourcing_strategy, vendor_code, promised_delivery_date,
      lead_time_working_days, standard_reference_lead_time_working_days, delivery_deviation_working_days,
      baseline_cost, procurement_cost, incremental_cost, cost_deviation_percentage, revenue, projected_margin,
      margin_percentage, is_expedited, requires_new_purchase_order, threshold_compliant, allocation_plan, deterministic_explanation
    )
    values (
      v_quote_id, 'AIR_FREIGHT', 'Air freight shortage sourcing', 'air_freight', v_primary.vendor_code, v_candidate_date,
      ceil(v_primary.lead_time_expedite_wd)::integer, v_primary.lead_time_standard_wd, 0,
      v_baseline_cost, (v_cost->>'procurement_cost')::numeric, (v_cost->>'procurement_cost')::numeric - v_baseline_cost,
      coalesce(((v_cost->>'procurement_cost')::numeric - v_baseline_cost) / nullif(v_baseline_cost, 0) * 100, 0),
      v_revenue, (v_cost->>'projected_margin')::numeric, (v_cost->>'margin_percentage')::numeric,
      true, v_shortage > 0, coalesce(((v_cost->>'procurement_cost')::numeric - v_baseline_cost) / nullif(v_baseline_cost, 0) * 100, 0) <= v_max_cost,
      v_plan, 'Air freight uses the standard vendor price plus contractual freight cost only for the uncovered shortage.'
    );
  end if;

  update public.quote_requests
  set calculation_completed_at = now(),
      response_time_ms = greatest(extract(milliseconds from clock_timestamp() - v_start)::integer, 1),
      status = 'pending_review',
      escalation_reason = 'No threshold-compliant option was auto-confirmed.',
      updated_at = now()
  where id = v_quote_id;

  select qo.id into v_best
  from public.quote_options as qo
  where qo.quote_request_id = v_quote_id and qo.threshold_compliant
  order by qo.promised_delivery_date, qo.procurement_cost, qo.projected_margin desc
  limit 1;

  if v_best is not null then
    begin
      perform public.confirm_quote_option(v_quote_id, v_best, 'automatic', null);
    exception when others then
      update public.quote_requests
      set status = 'stale', escalation_reason = 'Automatic confirmation failed: ' || sqlerrm, updated_at = now()
      where id = v_quote_id;
    end;
  end if;

  return query
  select qo.quote_request_id, qo.id, qo.option_code, qo.option_label, qo.sourcing_strategy,
         qo.promised_delivery_date, qo.procurement_cost, qo.incremental_cost, qo.projected_margin,
         qo.threshold_compliant, qo.deterministic_explanation
  from public.quote_options qo
  where qo.quote_request_id = v_quote_id
  order by qo.threshold_compliant desc, qo.promised_delivery_date, qo.procurement_cost;
end;
$$;

grant execute on function public.calculate_ctp_options(text, text, numeric, numeric, text) to authenticated;
