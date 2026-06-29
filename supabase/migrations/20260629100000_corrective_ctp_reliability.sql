alter table public.open_pos
  add column if not exists sourcing_mode text not null default 'imported',
  add column if not exists unit_cost numeric(12,4),
  add column if not exists status text not null default 'open',
  add column if not exists created_by_system boolean not null default false,
  add column if not exists originating_quote_request_id uuid references public.quote_requests(id),
  add column if not exists originating_commitment_id uuid references public.commitments(id),
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

alter table public.quote_requests
  add column if not exists recommended_option_id uuid references public.quote_options(id),
  add column if not exists recommendation_source text,
  add column if not exists recommendation_text text,
  add column if not exists recommendation_reasoning text,
  add column if not exists recommendation_main_risk text,
  add column if not exists recommendation_confidence numeric(4,3),
  add column if not exists escalation_reason text;

alter table public.commitments
  add column if not exists cancellation_reason text;

create or replace function public.delivery_delay_working_days(p_standard date, p_proposed date)
returns integer language sql immutable as $$
  select case
    when p_proposed <= p_standard then 0
    else public.working_days_between(p_standard, p_proposed)
  end;
$$;

create or replace function public.calculate_option_cost(p_plan jsonb, p_revenue numeric)
returns jsonb language plpgsql immutable as $$
declare
  v_item jsonb;
  v_cost numeric := 0;
begin
  for v_item in select * from jsonb_array_elements(coalesce(p_plan, '[]'::jsonb)) loop
    v_cost := v_cost + ((v_item->>'quantity')::numeric * coalesce((v_item->>'unit_cost')::numeric, 0));
  end loop;
  return jsonb_build_object(
    'procurement_cost', v_cost,
    'projected_margin', p_revenue - v_cost,
    'margin_percentage', coalesce((p_revenue - v_cost) / nullif(p_revenue, 0) * 100, 0)
  );
end;
$$;

drop view if exists public.current_item_atp;
drop view if exists public.open_po_availability;

create or replace view public.open_po_availability as
select
  op.po_id,
  op.vendor_code,
  v.vendor_name,
  op.material,
  op.quantity_ordered,
  coalesce(op.quantity_received, 0) as quantity_received,
  greatest(op.quantity_ordered - coalesce(op.quantity_received, 0), 0) as remaining_quantity,
  coalesce(a.allocated_quantity, 0) as allocated_quantity,
  greatest(op.quantity_ordered - coalesce(op.quantity_received, 0) - coalesce(a.allocated_quantity, 0), 0) as unallocated_quantity,
  op.expected_delivery_date,
  public.add_working_days(op.expected_delivery_date, public.get_setting_integer('open_po_buffer_working_days', 1)) as buffered_availability_date,
  op.expected_delivery_date < public.get_operational_date() and greatest(op.quantity_ordered - coalesce(op.quantity_received, 0), 0) > 0 as overdue,
  op.is_expedite,
  op.sourcing_mode,
  op.unit_cost,
  op.status,
  op.created_by_system,
  op.originating_quote_request_id,
  op.originating_commitment_id
from public.open_pos op
left join public.vendors v on v.vendor_code = op.vendor_code
left join (
  select source_po_id, sum(allocated_quantity) allocated_quantity
  from public.commitment_allocations ca
  join public.commitments c on c.id = ca.commitment_id
  where c.status = 'active' and ca.source_type in ('open_po', 'new_po')
  group by source_po_id
) a on a.source_po_id = op.po_id;

create or replace view public.current_item_atp as
select
  i.material,
  i.description,
  i.uom,
  i.current_stock,
  coalesce(stock_alloc.allocated_quantity, 0) as active_stock_allocation_quantity,
  coalesce(legacy_demand.quantity, 0) as active_legacy_demand_quantity,
  greatest(i.current_stock - coalesce(stock_alloc.allocated_quantity, 0) - coalesce(legacy_demand.quantity, 0), 0) as free_stock_quantity,
  i.avg_daily_demand,
  case when coalesce(i.avg_daily_demand, 0) > 0
    then round(greatest(i.current_stock - coalesce(stock_alloc.allocated_quantity, 0) - coalesce(legacy_demand.quantity, 0), 0) / i.avg_daily_demand, 2)
    else null end as stock_coverage_days,
  coalesce(po.incoming_quantity, 0) as incoming_po_quantity,
  coalesce(po.allocated_po_quantity, 0) as allocated_po_quantity,
  coalesce(po.overdue_po_quantity, 0) as overdue_po_quantity,
  po.next_expected_availability_date
from public.items i
left join (
  select c.material, sum(a.allocated_quantity) allocated_quantity
  from public.commitment_allocations a
  join public.commitments c on c.id = a.commitment_id
  where c.status = 'active' and a.source_type = 'stock'
  group by c.material
) stock_alloc on stock_alloc.material = i.material
left join (
  select material, sum(committed_quantity) quantity
  from public.commitments
  where status = 'active' and source_type = 'legacy_history'
  group by material
) legacy_demand on legacy_demand.material = i.material
left join (
  select
    material,
    sum(unallocated_quantity) incoming_quantity,
    sum(allocated_quantity) allocated_po_quantity,
    sum(case when overdue then unallocated_quantity else 0 end) overdue_po_quantity,
    min(buffered_availability_date) filter (where unallocated_quantity > 0) next_expected_availability_date
  from public.open_po_availability
  group by material
) po on po.material = i.material;

create or replace view public.dashboard_metrics as
select
  count(*) filter (where qr.requested_at::date = public.get_operational_date())::integer as quotations_processed_today,
  count(*) filter (where c.decision_type = 'automatic' and c.status in ('active', 'delivered'))::integer as automatically_confirmed_quotations,
  count(*) filter (where qr.status = 'pending_review')::integer as pending_review_quotations,
  coalesce(round(count(*) filter (where c.decision_type = 'automatic')::numeric / nullif(count(*) filter (where c.decision_type in ('automatic', 'human_confirmed', 'human_override')), 0), 4), 0) as automation_rate,
  round(avg(qr.response_time_ms), 0)::integer as average_response_time_ms,
  coalesce(round(count(*) filter (where c.status = 'delivered' and c.actual_delivery_date <= c.promised_delivery_date)::numeric / nullif(count(*) filter (where c.status = 'delivered'), 0), 4), 0) as delivery_accuracy,
  coalesce(sum(greatest(c.incremental_cost, 0)) filter (where c.status in ('active', 'delivered')), 0) as total_expedite_incremental_cost
from public.quote_requests qr
left join public.commitments c on c.quote_request_id = qr.id;

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

  if exists (select 1 from public.commitments where quote_request_id = v_quote_id and status = 'active') then
    return query
    select qo.quote_request_id, qo.id, qo.option_code, qo.option_label, qo.sourcing_strategy, qo.promised_delivery_date,
           qo.procurement_cost, qo.incremental_cost, qo.projected_margin, qo.threshold_compliant, qo.deterministic_explanation
    from public.quote_options qo where qo.quote_request_id = v_quote_id order by qo.threshold_compliant desc, qo.promised_delivery_date, qo.procurement_cost;
    return;
  end if;

  delete from public.quote_options where quote_request_id = v_quote_id;

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
      v_quote_id, 'OPEN_PO', 'Stock plus open PO', 'existing_open_po', v_primary.vendor_code, v_candidate_date,
      public.working_days_between(v_op_date, v_candidate_date), coalesce(v_primary.lead_time_standard_wd, 7), public.delivery_delay_working_days(v_standard_date, v_candidate_date),
      v_baseline_cost, (v_cost->>'procurement_cost')::numeric, (v_cost->>'procurement_cost')::numeric - v_baseline_cost,
      coalesce(((v_cost->>'procurement_cost')::numeric - v_baseline_cost) / nullif(v_baseline_cost, 0) * 100, 0),
      v_revenue, (v_cost->>'projected_margin')::numeric, (v_cost->>'margin_percentage')::numeric,
      not v_has_overdue and public.delivery_delay_working_days(v_standard_date, v_candidate_date) <= v_max_delivery,
      v_plan,
      case when v_has_overdue then 'Uses an overdue open purchase order and requires human verification.' else 'Usable stock and open purchase orders cover the complete quantity.' end
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
      v_shortage > 0, true, v_plan,
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

  select id into v_best
  from public.quote_options
  where quote_request_id = v_quote_id and threshold_compliant
  order by promised_delivery_date, procurement_cost, projected_margin desc
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

create or replace function public.confirm_quote_option(
  p_quote_request_id uuid,
  p_option_id uuid,
  p_decision_type text default 'human_confirmed',
  p_override_reason text default null
) returns uuid language plpgsql security definer set search_path = public, auth as $$
declare
  v_actor uuid := auth.uid();
  v_role text := public.current_user_role();
  v_quote public.quote_requests%rowtype;
  v_option public.quote_options%rowtype;
  v_commitment_id uuid;
  v_item jsonb;
  v_total numeric := 0;
  v_available numeric;
  v_source_po_id text;
  v_new_po_id text;
  v_recommended uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_decision_type not in ('automatic', 'human_confirmed', 'human_override') then raise exception 'INVALID_DECISION_TYPE'; end if;
  if p_decision_type in ('human_confirmed', 'human_override') and v_role not in ('manager', 'admin') then raise exception 'MANAGER_ROLE_REQUIRED'; end if;

  select * into v_quote from public.quote_requests where id = p_quote_request_id for update;
  select * into v_option from public.quote_options where id = p_option_id and quote_request_id = p_quote_request_id;
  if v_quote.id is null or v_option.id is null then raise exception 'QUOTE_OR_OPTION_NOT_FOUND'; end if;

  select coalesce(v_quote.recommended_option_id,
    (select id from public.quote_options where quote_request_id = v_quote.id order by threshold_compliant desc, promised_delivery_date, procurement_cost limit 1)
  ) into v_recommended;

  if p_decision_type = 'human_override' and (coalesce(trim(p_override_reason), '') = '' or p_option_id = v_recommended) then
    raise exception 'OVERRIDE_REASON_REQUIRED';
  end if;

  if exists (select 1 from public.commitments where quote_request_id = p_quote_request_id and status = 'active') then
    select id into v_commitment_id from public.commitments where quote_request_id = p_quote_request_id and status = 'active';
    return v_commitment_id;
  end if;

  perform pg_advisory_xact_lock(hashtext(v_quote.material));
  perform 1 from public.items where material = v_quote.material for update;
  perform 1 from public.open_pos
  where po_id in (
    select value->>'source_po_id'
    from jsonb_array_elements(v_option.allocation_plan)
    where value->>'source_type' = 'open_po'
  )
  for update;

  for v_item in select * from jsonb_array_elements(v_option.allocation_plan) loop
    v_total := v_total + (v_item->>'quantity')::numeric;

    if (v_item->>'source_type') = 'stock' then
      select greatest(i.current_stock - coalesce(sa.qty, 0) - coalesce(ld.qty, 0), 0)
      into v_available
      from public.items i
      left join (
        select c.material, sum(a.allocated_quantity) qty
        from public.commitment_allocations a join public.commitments c on c.id = a.commitment_id
        where c.status = 'active' and a.source_type = 'stock' and c.material = v_quote.material
        group by c.material
      ) sa on sa.material = i.material
      left join (
        select material, sum(committed_quantity) qty
        from public.commitments
        where status = 'active' and source_type = 'legacy_history' and material = v_quote.material
        group by material
      ) ld on ld.material = i.material
      where i.material = v_quote.material;
      if coalesce(v_available, 0) < (v_item->>'quantity')::numeric then
        update public.quote_requests set status = 'stale', updated_at = now(), escalation_reason = 'Availability has changed since calculation.' where id = v_quote.id;
        raise exception 'STALE_QUOTE';
      end if;
    elsif (v_item->>'source_type') = 'open_po' then
      v_source_po_id := v_item->>'source_po_id';
      select greatest(op.quantity_ordered - coalesce(op.quantity_received, 0) - coalesce(a.qty, 0), 0)
      into v_available
      from public.open_pos op
      left join (
        select source_po_id, sum(allocated_quantity) qty
        from public.commitment_allocations ca join public.commitments c on c.id = ca.commitment_id
        where c.status = 'active' and ca.source_po_id = v_source_po_id
        group by source_po_id
      ) a on a.source_po_id = op.po_id
      where op.po_id = v_source_po_id;
      if coalesce(v_available, 0) < (v_item->>'quantity')::numeric then
        update public.quote_requests set status = 'stale', updated_at = now(), escalation_reason = 'Open PO availability has changed since calculation.' where id = v_quote.id;
        raise exception 'STALE_QUOTE';
      end if;
    elsif (v_item->>'source_type') <> 'new_po' then
      raise exception 'INVALID_ALLOCATION_PLAN';
    end if;
  end loop;

  if abs(v_total - v_quote.requested_quantity) > 0.0001 then
    raise exception 'INVALID_ALLOCATION_TOTAL';
  end if;

  insert into public.commitments (
    quote_request_id, quote_option_id, customer_id, material, committed_quantity, promised_delivery_date,
    selling_unit_price, procurement_cost, incremental_cost, projected_margin, decision_type, source_type, created_by
  )
  values (
    v_quote.id, v_option.id, v_quote.customer_id, v_quote.material, v_quote.requested_quantity, v_option.promised_delivery_date,
    v_quote.selling_unit_price, v_option.procurement_cost, v_option.incremental_cost, v_option.projected_margin,
    case when p_decision_type = 'automatic' then 'automatic' when p_decision_type = 'human_override' then 'human_override' else 'human_confirmed' end,
    v_option.sourcing_strategy, v_actor
  )
  returning id into v_commitment_id;

  for v_item in select * from jsonb_array_elements(v_option.allocation_plan) loop
    v_source_po_id := nullif(v_item->>'source_po_id', '');
    if (v_item->>'source_type') = 'new_po' then
      v_new_po_id := 'SYS-' || upper(replace(substr(gen_random_uuid()::text, 1, 13), '-', ''));
      insert into public.open_pos (
        po_id, vendor_code, material, quantity_ordered, quantity_received, expected_delivery_date, is_expedite,
        sourcing_mode, unit_cost, status, created_by_system, originating_quote_request_id, originating_commitment_id
      )
      values (
        v_new_po_id,
        v_item->>'vendor_code',
        v_quote.material,
        (v_item->>'quantity')::numeric,
        0,
        (v_item->>'availability_date')::date,
        coalesce((v_item->>'sourcing_mode') in ('fast_track', 'air_freight'), false),
        coalesce(v_item->>'sourcing_mode', 'standard'),
        coalesce((v_item->>'unit_cost')::numeric, 0),
        'open',
        true,
        v_quote.id,
        v_commitment_id
      );
      v_source_po_id := v_new_po_id;
    end if;

    insert into public.commitment_allocations (commitment_id, source_type, source_po_id, allocated_quantity, availability_date, unit_cost)
    values (
      v_commitment_id,
      v_item->>'source_type',
      v_source_po_id,
      (v_item->>'quantity')::numeric,
      (v_item->>'availability_date')::date,
      coalesce((v_item->>'unit_cost')::numeric, 0)
    );
  end loop;

  insert into public.decision_logs (
    quote_request_id, recommended_option_id, selected_option_id, decision_type,
    llm_recommendation, llm_reasoning, llm_main_risk, llm_confidence,
    deterministic_fallback_reasoning, override_reason, threshold_snapshot, actor_id
  )
  values (
    v_quote.id,
    v_recommended,
    v_option.id,
    case when p_decision_type = 'automatic' then 'automatic' when p_decision_type = 'human_override' then 'human_override' else 'human_confirmed' end,
    v_quote.recommendation_text,
    v_quote.recommendation_reasoning,
    v_quote.recommendation_main_risk,
    v_quote.recommendation_confidence,
    v_option.deterministic_explanation,
    p_override_reason,
    jsonb_build_object('max_delivery_deviation_working_days', public.get_setting_integer('max_delivery_deviation_working_days', 0), 'max_cost_deviation_percentage', public.get_setting_decimal('max_cost_deviation_percentage', 0)),
    v_actor
  );

  update public.quote_requests
  set status = case when p_decision_type = 'automatic' then 'auto_confirmed' when p_decision_type = 'human_override' then 'overridden' else 'human_confirmed' end,
      recommended_option_id = coalesce(recommended_option_id, v_recommended),
      updated_at = now()
  where id = v_quote.id;

  return v_commitment_id;
end;
$$;

create or replace function public.persist_quote_recommendation(
  p_quote_request_id uuid,
  p_recommended_option_id uuid,
  p_source text,
  p_recommendation text,
  p_reasoning text,
  p_main_risk text,
  p_confidence numeric
) returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists (select 1 from public.quote_options where id = p_recommended_option_id and quote_request_id = p_quote_request_id) then
    raise exception 'INVALID_RECOMMENDED_OPTION';
  end if;
  update public.quote_requests
  set recommended_option_id = p_recommended_option_id,
      recommendation_source = p_source,
      recommendation_text = p_recommendation,
      recommendation_reasoning = p_reasoning,
      recommendation_main_risk = p_main_risk,
      recommendation_confidence = p_confidence,
      updated_at = now()
  where id = p_quote_request_id;
end;
$$;

create or replace function public.update_system_setting(
  p_setting_key text,
  p_boolean_value boolean default null,
  p_date_value date default null,
  p_integer_value integer default null,
  p_decimal_value numeric default null,
  p_text_value text default null
) returns void language plpgsql security definer set search_path = public, auth as $$
declare
  v_type text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if public.current_user_role() <> 'admin' then raise exception 'ADMIN_ROLE_REQUIRED'; end if;
  select setting_type into v_type from public.system_settings where setting_key = p_setting_key for update;
  if v_type is null then raise exception 'UNKNOWN_SETTING'; end if;
  update public.system_settings
  set boolean_value = case when v_type = 'boolean' then p_boolean_value else boolean_value end,
      date_value = case when v_type = 'date' then p_date_value else date_value end,
      integer_value = case when v_type = 'integer' then p_integer_value else integer_value end,
      decimal_value = case when v_type = 'decimal' then p_decimal_value else decimal_value end,
      text_value = case when v_type = 'text' then p_text_value else text_value end,
      updated_by = auth.uid(),
      updated_at = now()
  where setting_key = p_setting_key;
end;
$$;

create or replace function public.set_commitment_status(
  p_commitment_id uuid,
  p_status text,
  p_actual_delivery_date date default null,
  p_cancellation_reason text default null
) returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.is_manager_or_admin() then raise exception 'MANAGER_ROLE_REQUIRED'; end if;
  if p_status not in ('delivered', 'cancelled') then raise exception 'INVALID_STATUS'; end if;
  if p_status = 'cancelled' and coalesce(trim(p_cancellation_reason), '') = '' then raise exception 'CANCELLATION_REASON_REQUIRED'; end if;
  update public.commitments
  set status = p_status,
      actual_delivery_date = case when p_status = 'delivered' then coalesce(p_actual_delivery_date, public.get_operational_date()) else actual_delivery_date end,
      cancelled_at = case when p_status = 'cancelled' then now() else cancelled_at end,
      cancellation_reason = case when p_status = 'cancelled' then p_cancellation_reason else cancellation_reason end,
      updated_at = now()
  where id = p_commitment_id;
end;
$$;

insert into public.commitments (
  source_order_id, customer_id, material, committed_quantity, promised_delivery_date, selling_unit_price,
  procurement_cost, incremental_cost, projected_margin, decision_type, status, source_type, confirmed_at
)
select
  oh.order_id, oh.customer_id::text, oh.material, oh.quantity, oh.promised_date, oh.unit_price_charged,
  coalesce(oh.quantity * oh.unit_cost, 0), 0, coalesce(oh.quantity * (oh.unit_price_charged - oh.unit_cost), 0),
  'legacy_import', 'active', 'legacy_history', now()
from public.orders_history oh
where oh.actual_delivery_date is null
  and oh.customer_id is not null
  and oh.material is not null
  and oh.quantity > 0
on conflict (source_order_id) do nothing;

create or replace view public.legacy_open_demand_summary as
select
  count(*)::integer as open_legacy_order_count,
  coalesce(sum(committed_quantity), 0) as open_legacy_quantity,
  min(promised_delivery_date) as earliest_promised_date,
  max(promised_delivery_date) as latest_promised_date
from public.commitments
where source_type = 'legacy_history' and status = 'active';

grant select on public.legacy_open_demand_summary to authenticated;
grant select on public.current_item_atp, public.open_po_availability, public.dashboard_metrics to authenticated;
grant execute on function public.delivery_delay_working_days(date, date) to authenticated;
grant execute on function public.persist_quote_recommendation(uuid, uuid, text, text, text, text, numeric) to authenticated;
grant execute on function public.update_system_setting(text, boolean, date, integer, numeric, text) to authenticated;
grant execute on function public.set_commitment_status(uuid, text, date, text) to authenticated;
