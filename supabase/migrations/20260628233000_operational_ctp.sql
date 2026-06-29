create extension if not exists pgcrypto with schema extensions;

create table if not exists public.customers (
  customer_id text primary key,
  customer_name text,
  customer_tier text not null default 'C' check (customer_tier in ('A', 'B', 'C')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.customers (customer_id, customer_tier)
select customer_id::text, coalesce(max(customer_tier), 'C')::text
from public.orders_history
where customer_id is not null
group by customer_id
on conflict (customer_id) do update
set customer_tier = excluded.customer_tier,
    updated_at = now();

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  role text not null default 'sales' check (role in ('sales', 'manager', 'admin')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.system_settings (
  setting_key text primary key,
  setting_type text not null check (setting_type in ('boolean', 'date', 'integer', 'decimal', 'text')),
  boolean_value boolean,
  date_value date,
  integer_value integer,
  decimal_value numeric(12,4),
  text_value text,
  description text not null,
  unit text,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

insert into public.system_settings (setting_key, setting_type, boolean_value, date_value, integer_value, decimal_value, text_value, description, unit)
values
  ('demo_mode_enabled', 'boolean', true, null, null, null, null, 'Use a reproducible business date for the assignment dataset.', null),
  ('operational_reference_date', 'date', null, '2026-06-12', null, null, null, 'Reference date used while demo mode is enabled.', 'date'),
  ('max_delivery_deviation_working_days', 'integer', null, null, 0, null, null, 'Maximum delivery deviation allowed for automatic confirmation.', 'working days'),
  ('max_cost_deviation_percentage', 'decimal', null, null, null, 0, null, 'Maximum incremental cost percentage allowed for automatic confirmation.', 'percent'),
  ('open_po_buffer_working_days', 'integer', null, null, 1, null, null, 'Working-day buffer applied to open purchase order dates.', 'working days'),
  ('stock_fulfillment_lead_time_working_days', 'integer', null, null, 2, null, null, 'Internal fulfillment lead time when current stock covers the request.', 'working days'),
  ('stock_coverage_alert_days', 'integer', null, null, 3, null, null, 'Coverage threshold used for low-stock dashboard alerts.', 'days'),
  ('llm_recommendation_enabled', 'boolean', true, null, null, null, null, 'Enable AI recommendation Edge Function when configured.', null)
on conflict (setting_key) do nothing;

create table if not exists public.vendor_reliability (
  vendor_code varchar(10) primary key references public.vendors(vendor_code),
  reliability_score numeric(4,3) not null default 0.900 check (reliability_score between 0 and 1),
  updated_at timestamptz not null default now()
);

insert into public.vendor_reliability (vendor_code)
select vendor_code from public.vendors
on conflict (vendor_code) do nothing;

create table if not exists public.quote_requests (
  id uuid primary key default gen_random_uuid(),
  customer_id text not null references public.customers(customer_id),
  customer_tier_snapshot text not null check (customer_tier_snapshot in ('A', 'B', 'C')),
  material varchar(20) not null references public.items(material),
  requested_quantity numeric(12,2) not null check (requested_quantity > 0),
  selling_unit_price numeric(12,4) not null check (selling_unit_price > 0),
  requested_at timestamptz not null default now(),
  calculation_completed_at timestamptz,
  response_time_ms integer,
  status text not null default 'calculating' check (status in ('draft', 'calculating', 'auto_confirmed', 'pending_review', 'human_confirmed', 'overridden', 'stale', 'cancelled', 'failed')),
  idempotency_key text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists quote_requests_idempotency_idx
on public.quote_requests (created_by, idempotency_key)
where idempotency_key is not null;

create table if not exists public.quote_options (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  option_code text not null,
  option_label text not null,
  sourcing_strategy text not null check (sourcing_strategy in ('current_stock', 'existing_open_po', 'new_standard_po', 'secondary_standard_vendor', 'fast_track', 'air_freight', 'combined_supply')),
  vendor_code varchar(10) references public.vendors(vendor_code),
  promised_delivery_date date not null,
  lead_time_working_days integer not null,
  standard_reference_lead_time_working_days integer,
  delivery_deviation_working_days integer not null default 0,
  baseline_cost numeric(14,4) not null,
  procurement_cost numeric(14,4) not null,
  incremental_cost numeric(14,4) not null,
  cost_deviation_percentage numeric(12,4) not null,
  revenue numeric(14,4) not null,
  projected_margin numeric(14,4) not null,
  margin_percentage numeric(12,4) not null,
  is_expedited boolean not null default false,
  requires_new_purchase_order boolean not null default false,
  threshold_compliant boolean not null default false,
  feasible boolean not null default true,
  allocation_plan jsonb not null default '[]'::jsonb,
  deterministic_explanation text not null,
  created_at timestamptz not null default now(),
  unique (quote_request_id, option_code)
);

create table if not exists public.commitments (
  id uuid primary key default gen_random_uuid(),
  source_order_id varchar(20) unique,
  quote_request_id uuid references public.quote_requests(id),
  quote_option_id uuid references public.quote_options(id),
  customer_id text not null references public.customers(customer_id),
  material varchar(20) not null references public.items(material),
  committed_quantity numeric(12,2) not null check (committed_quantity > 0),
  promised_delivery_date date not null,
  selling_unit_price numeric(12,4) not null,
  procurement_cost numeric(14,4) not null default 0,
  incremental_cost numeric(14,4) not null default 0,
  projected_margin numeric(14,4) not null default 0,
  decision_type text not null check (decision_type in ('legacy_import', 'automatic', 'human_confirmed', 'human_override')),
  status text not null default 'active' check (status in ('active', 'delivered', 'cancelled')),
  source_type text not null,
  confirmed_at timestamptz not null default now(),
  actual_delivery_date date,
  cancelled_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists commitments_one_active_quote_idx
on public.commitments (quote_request_id)
where quote_request_id is not null and status = 'active';

create table if not exists public.commitment_allocations (
  id uuid primary key default gen_random_uuid(),
  commitment_id uuid not null references public.commitments(id) on delete cascade,
  source_type text not null check (source_type in ('stock', 'open_po', 'new_po')),
  source_po_id varchar(20) references public.open_pos(po_id),
  allocated_quantity numeric(12,2) not null check (allocated_quantity > 0),
  availability_date date not null,
  unit_cost numeric(12,4) not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.decision_logs (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id),
  recommended_option_id uuid references public.quote_options(id),
  selected_option_id uuid references public.quote_options(id),
  decision_type text not null check (decision_type in ('automatic', 'human_confirmed', 'human_override')),
  llm_recommendation text,
  llm_reasoning text,
  llm_main_risk text,
  llm_confidence numeric(4,3) check (llm_confidence between 0 and 1),
  deterministic_fallback_reasoning text,
  override_reason text,
  threshold_snapshot jsonb not null default '{}'::jsonb,
  actor_id uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint human_override_reason check (decision_type <> 'human_override' or (override_reason is not null and selected_option_id is distinct from recommended_option_id))
);

create table if not exists public.inventory_adjustments (
  id uuid primary key default gen_random_uuid(),
  material varchar(20) not null references public.items(material),
  previous_quantity numeric(12,2) not null,
  new_quantity numeric(12,2) not null,
  quantity_delta numeric(12,2) not null,
  reason text not null check (length(trim(reason)) > 0),
  adjusted_by uuid references auth.users(id),
  adjusted_at timestamptz not null default now()
);

create or replace function public.get_setting_boolean(p_key text, p_default boolean)
returns boolean language sql stable set search_path = public as $$
  select coalesce((select boolean_value from public.system_settings where setting_key = p_key), p_default);
$$;

create or replace function public.get_setting_integer(p_key text, p_default integer)
returns integer language sql stable set search_path = public as $$
  select coalesce((select integer_value from public.system_settings where setting_key = p_key), p_default);
$$;

create or replace function public.get_setting_decimal(p_key text, p_default numeric)
returns numeric language sql stable set search_path = public as $$
  select coalesce((select decimal_value from public.system_settings where setting_key = p_key), p_default);
$$;

create or replace function public.get_operational_date()
returns date language sql stable set search_path = public as $$
  select case
    when public.get_setting_boolean('demo_mode_enabled', true)
      then coalesce((select date_value from public.system_settings where setting_key = 'operational_reference_date'), current_date)
    else current_date
  end;
$$;

create or replace function public.add_working_days(p_start date, p_days integer)
returns date language plpgsql immutable as $$
declare
  v_date date := p_start;
  v_remaining integer := greatest(p_days, 0);
begin
  while v_remaining > 0 loop
    v_date := v_date + 1;
    if extract(isodow from v_date) < 6 then
      v_remaining := v_remaining - 1;
    end if;
  end loop;
  return v_date;
end;
$$;

create or replace function public.working_days_between(p_start date, p_end date)
returns integer language sql immutable as $$
  select coalesce(count(*)::integer, 0)
  from generate_series(least(p_start, p_end) + 1, greatest(p_start, p_end), interval '1 day') d(day)
  where extract(isodow from d.day) < 6;
$$;

create or replace function public.current_user_role()
returns text language sql stable security definer set search_path = public, auth as $$
  select coalesce((select role from public.profiles where user_id = auth.uid()), 'sales');
$$;

create or replace function public.is_manager_or_admin()
returns boolean language sql stable security definer set search_path = public, auth as $$
  select public.current_user_role() in ('manager', 'admin');
$$;

create or replace view public.current_item_atp as
select
  i.material,
  i.description,
  i.uom,
  i.current_stock,
  coalesce(stock_alloc.allocated_quantity, 0) as active_stock_allocation_quantity,
  greatest(i.current_stock - coalesce(stock_alloc.allocated_quantity, 0), 0) as free_stock_quantity,
  i.avg_daily_demand,
  case when coalesce(i.avg_daily_demand, 0) > 0
    then round(greatest(i.current_stock - coalesce(stock_alloc.allocated_quantity, 0), 0) / i.avg_daily_demand, 2)
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
  select
    op.material,
    sum(greatest(op.quantity_ordered - coalesce(op.quantity_received, 0), 0)) incoming_quantity,
    coalesce(sum(a.allocated_quantity), 0) allocated_po_quantity,
    sum(case when op.expected_delivery_date < public.get_operational_date() then greatest(op.quantity_ordered - coalesce(op.quantity_received, 0), 0) else 0 end) overdue_po_quantity,
    min(public.add_working_days(op.expected_delivery_date, public.get_setting_integer('open_po_buffer_working_days', 1))) next_expected_availability_date
  from public.open_pos op
  left join public.commitment_allocations a on a.source_po_id = op.po_id
  group by op.material
) po on po.material = i.material;

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
  op.expected_delivery_date < public.get_operational_date() as overdue,
  op.is_expedite,
  case when op.is_expedite then 'expedite' else 'standard' end as status
from public.open_pos op
left join public.vendors v on v.vendor_code = op.vendor_code
left join (
  select source_po_id, sum(allocated_quantity) allocated_quantity
  from public.commitment_allocations ca
  join public.commitments c on c.id = ca.commitment_id
  where c.status = 'active' and ca.source_type = 'open_po'
  group by source_po_id
) a on a.source_po_id = op.po_id;

create or replace view public.dashboard_metrics as
select
  count(*) filter (where qr.requested_at::date = public.get_operational_date())::integer as quotations_processed_today,
  count(*) filter (where qr.status = 'auto_confirmed')::integer as automatically_confirmed_quotations,
  count(*) filter (where qr.status = 'pending_review')::integer as pending_review_quotations,
  coalesce(round(count(*) filter (where qr.status = 'auto_confirmed')::numeric / nullif(count(*) filter (where qr.status in ('auto_confirmed', 'human_confirmed', 'overridden')), 0), 4), 0) as automation_rate,
  round(avg(qr.response_time_ms), 0)::integer as average_response_time_ms,
  coalesce(round(count(*) filter (where c.status = 'delivered' and c.actual_delivery_date <= c.promised_delivery_date)::numeric / nullif(count(*) filter (where c.status = 'delivered'), 0), 4), 0) as delivery_accuracy,
  coalesce(sum(greatest(c.incremental_cost, 0)), 0) as total_expedite_incremental_cost
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
  v_po_buffer integer := public.get_setting_integer('open_po_buffer_working_days', 1);
  v_max_delivery integer := public.get_setting_integer('max_delivery_deviation_working_days', 0);
  v_max_cost numeric := public.get_setting_decimal('max_cost_deviation_percentage', 0);
  v_free_stock numeric;
  v_primary public.contracts%rowtype;
  v_secondary public.contracts%rowtype;
  v_revenue numeric;
  v_baseline_unit numeric;
  v_standard_date date;
  v_threshold boolean;
  v_plan jsonb;
  v_po record;
  v_accum numeric;
  v_last_date date;
begin
  if v_actor is null then
    raise exception 'AUTH_REQUIRED';
  end if;
  if p_requested_quantity <= 0 or p_selling_unit_price <= 0 then
    raise exception 'INVALID_QUOTE_INPUT';
  end if;

  select * into v_customer from public.customers where customer_id = p_customer_id;
  select * into v_item from public.items where material = p_material;
  if v_customer.customer_id is null or v_item.material is null then
    raise exception 'UNKNOWN_CUSTOMER_OR_MATERIAL';
  end if;

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
  v_standard_date := public.add_working_days(v_op_date, coalesce(v_primary.lead_time_standard_wd, v_secondary.lead_time_standard_wd, 7));

  insert into public.quote_requests (customer_id, customer_tier_snapshot, material, requested_quantity, selling_unit_price, status, idempotency_key, created_by)
  values (p_customer_id, v_customer.customer_tier, p_material, p_requested_quantity, p_selling_unit_price, 'calculating', p_idempotency_key, v_actor)
  on conflict (created_by, idempotency_key) where idempotency_key is not null
  do update set updated_at = now()
  returning id into v_quote_id;

  delete from public.quote_options where quote_request_id = v_quote_id;

  select greatest(v_item.current_stock - coalesce(sum(a.allocated_quantity) filter (where a.source_type = 'stock'), 0), 0)
  into v_free_stock
  from public.commitment_allocations a
  join public.commitments c on c.id = a.commitment_id and c.status = 'active' and c.material = p_material;
  v_free_stock := coalesce(v_free_stock, v_item.current_stock);

  if v_free_stock >= p_requested_quantity then
    v_threshold := true;
    insert into public.quote_options (
      quote_request_id, option_code, option_label, sourcing_strategy, vendor_code, promised_delivery_date,
      lead_time_working_days, standard_reference_lead_time_working_days, delivery_deviation_working_days,
      baseline_cost, procurement_cost, incremental_cost, cost_deviation_percentage, revenue, projected_margin,
      margin_percentage, threshold_compliant, allocation_plan, deterministic_explanation
    )
    values (
      v_quote_id, 'STOCK', 'Current stock', 'current_stock', null, public.add_working_days(v_op_date, v_stock_lead),
      v_stock_lead, coalesce(v_primary.lead_time_standard_wd, 7), 0,
      p_requested_quantity * v_baseline_unit, p_requested_quantity * v_baseline_unit, 0, 0, v_revenue, v_revenue - p_requested_quantity * v_baseline_unit,
      (v_revenue - p_requested_quantity * v_baseline_unit) / nullif(v_revenue, 0) * 100, true,
      jsonb_build_array(jsonb_build_object('source_type','stock','quantity',p_requested_quantity,'availability_date',public.add_working_days(v_op_date, v_stock_lead),'unit_cost',v_baseline_unit)),
      'Current unallocated stock covers the complete requested quantity.'
    );
  end if;

  v_accum := least(v_free_stock, p_requested_quantity);
  v_plan := case when v_accum > 0 then jsonb_build_array(jsonb_build_object('source_type','stock','quantity',v_accum,'availability_date',public.add_working_days(v_op_date, v_stock_lead),'unit_cost',v_baseline_unit)) else '[]'::jsonb end;
  v_last_date := public.add_working_days(v_op_date, v_stock_lead);
  for v_po in
    select po_id, vendor_code, unallocated_quantity, buffered_availability_date
    from public.open_po_availability
    where material = p_material and unallocated_quantity > 0
    order by buffered_availability_date, po_id
  loop
    exit when v_accum >= p_requested_quantity;
    v_plan := v_plan || jsonb_build_array(jsonb_build_object('source_type','open_po','source_po_id',v_po.po_id,'quantity',least(v_po.unallocated_quantity, p_requested_quantity - v_accum),'availability_date',v_po.buffered_availability_date,'unit_cost',v_baseline_unit));
    v_accum := v_accum + least(v_po.unallocated_quantity, p_requested_quantity - v_accum);
    v_last_date := greatest(v_last_date, v_po.buffered_availability_date);
  end loop;

  if v_accum >= p_requested_quantity then
    insert into public.quote_options (
      quote_request_id, option_code, option_label, sourcing_strategy, vendor_code, promised_delivery_date,
      lead_time_working_days, standard_reference_lead_time_working_days, delivery_deviation_working_days,
      baseline_cost, procurement_cost, incremental_cost, cost_deviation_percentage, revenue, projected_margin,
      margin_percentage, threshold_compliant, allocation_plan, deterministic_explanation
    )
    values (
      v_quote_id, 'OPEN_PO', 'Current stock plus open PO', 'existing_open_po', v_primary.vendor_code, v_last_date,
      public.working_days_between(v_op_date, v_last_date), coalesce(v_primary.lead_time_standard_wd, 7), greatest(public.working_days_between(v_standard_date, v_last_date), 0),
      p_requested_quantity * v_baseline_unit, p_requested_quantity * v_baseline_unit, 0, 0, v_revenue, v_revenue - p_requested_quantity * v_baseline_unit,
      (v_revenue - p_requested_quantity * v_baseline_unit) / nullif(v_revenue, 0) * 100,
      greatest(public.working_days_between(v_standard_date, v_last_date), 0) <= v_max_delivery, v_plan,
      'Available stock and unallocated open purchase orders cover the complete quantity on one delivery date.'
    );
  end if;

  if v_primary.contract_id is not null then
    insert into public.quote_options (
      quote_request_id, option_code, option_label, sourcing_strategy, vendor_code, promised_delivery_date,
      lead_time_working_days, standard_reference_lead_time_working_days, delivery_deviation_working_days,
      baseline_cost, procurement_cost, incremental_cost, cost_deviation_percentage, revenue, projected_margin,
      margin_percentage, requires_new_purchase_order, threshold_compliant, allocation_plan, deterministic_explanation
    )
    values (
      v_quote_id, 'STD_PRIMARY', 'New standard PO', 'new_standard_po', v_primary.vendor_code, v_standard_date,
      v_primary.lead_time_standard_wd, v_primary.lead_time_standard_wd, 0,
      p_requested_quantity * v_primary.unit_price_standard, p_requested_quantity * v_primary.unit_price_standard, 0, 0,
      v_revenue, v_revenue - p_requested_quantity * v_primary.unit_price_standard,
      (v_revenue - p_requested_quantity * v_primary.unit_price_standard) / nullif(v_revenue, 0) * 100,
      true, true,
      jsonb_build_array(jsonb_build_object('source_type','new_po','quantity',p_requested_quantity,'availability_date',v_standard_date,'unit_cost',v_primary.unit_price_standard)),
      'A new standard purchase order with the primary vendor can cover the complete quantity.'
    );
  end if;

  if v_secondary.contract_id is not null then
    insert into public.quote_options (
      quote_request_id, option_code, option_label, sourcing_strategy, vendor_code, promised_delivery_date,
      lead_time_working_days, standard_reference_lead_time_working_days, delivery_deviation_working_days,
      baseline_cost, procurement_cost, incremental_cost, cost_deviation_percentage, revenue, projected_margin,
      margin_percentage, requires_new_purchase_order, threshold_compliant, allocation_plan, deterministic_explanation
    )
    values (
      v_quote_id, 'STD_SECONDARY', 'Secondary standard vendor', 'secondary_standard_vendor', v_secondary.vendor_code,
      public.add_working_days(v_op_date, v_secondary.lead_time_standard_wd),
      v_secondary.lead_time_standard_wd, coalesce(v_primary.lead_time_standard_wd, v_secondary.lead_time_standard_wd), greatest(v_secondary.lead_time_standard_wd - coalesce(v_primary.lead_time_standard_wd, v_secondary.lead_time_standard_wd), 0),
      p_requested_quantity * v_baseline_unit, p_requested_quantity * v_secondary.unit_price_standard,
      p_requested_quantity * (v_secondary.unit_price_standard - v_baseline_unit),
      ((v_secondary.unit_price_standard - v_baseline_unit) / nullif(v_baseline_unit, 0)) * 100,
      v_revenue, v_revenue - p_requested_quantity * v_secondary.unit_price_standard,
      (v_revenue - p_requested_quantity * v_secondary.unit_price_standard) / nullif(v_revenue, 0) * 100,
      true, (((v_secondary.unit_price_standard - v_baseline_unit) / nullif(v_baseline_unit, 0)) * 100) <= v_max_cost,
      jsonb_build_array(jsonb_build_object('source_type','new_po','quantity',p_requested_quantity,'availability_date',public.add_working_days(v_op_date, v_secondary.lead_time_standard_wd),'unit_cost',v_secondary.unit_price_standard)),
      'A secondary vendor can supply the complete quantity under a standard purchase order.'
    );
  end if;

  if v_secondary.contract_id is not null and v_secondary.unit_price_expedite is not null and v_secondary.lead_time_expedite_wd is not null then
    insert into public.quote_options (
      quote_request_id, option_code, option_label, sourcing_strategy, vendor_code, promised_delivery_date,
      lead_time_working_days, standard_reference_lead_time_working_days, delivery_deviation_working_days,
      baseline_cost, procurement_cost, incremental_cost, cost_deviation_percentage, revenue, projected_margin,
      margin_percentage, is_expedited, requires_new_purchase_order, threshold_compliant, allocation_plan, deterministic_explanation
    )
    values (
      v_quote_id, 'FAST_TRACK', 'Fast-track purchase', 'fast_track', v_secondary.vendor_code,
      public.add_working_days(v_op_date, ceil(v_secondary.lead_time_expedite_wd)::integer),
      ceil(v_secondary.lead_time_expedite_wd)::integer, coalesce(v_primary.lead_time_standard_wd, v_secondary.lead_time_standard_wd), 0,
      p_requested_quantity * v_baseline_unit, p_requested_quantity * v_secondary.unit_price_expedite,
      p_requested_quantity * (v_secondary.unit_price_expedite - v_baseline_unit),
      ((v_secondary.unit_price_expedite - v_baseline_unit) / nullif(v_baseline_unit, 0)) * 100,
      v_revenue, v_revenue - p_requested_quantity * v_secondary.unit_price_expedite,
      (v_revenue - p_requested_quantity * v_secondary.unit_price_expedite) / nullif(v_revenue, 0) * 100,
      true, true, (((v_secondary.unit_price_expedite - v_baseline_unit) / nullif(v_baseline_unit, 0)) * 100) <= v_max_cost,
      jsonb_build_array(jsonb_build_object('source_type','new_po','quantity',p_requested_quantity,'availability_date',public.add_working_days(v_op_date, ceil(v_secondary.lead_time_expedite_wd)::integer),'unit_cost',v_secondary.unit_price_expedite)),
      'Fast-track sourcing uses the expedited contractual price and lead time.'
    );
  end if;

  update public.quote_requests
  set calculation_completed_at = now(),
      response_time_ms = greatest(extract(milliseconds from clock_timestamp() - v_start)::integer, 1),
      status = case
        when exists (select 1 from public.quote_options where quote_request_id = v_quote_id and threshold_compliant)
          then 'auto_confirmed'
        else 'pending_review'
      end,
      updated_at = now()
  where id = v_quote_id;

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
  v_plan jsonb;
  v_item jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_quote from public.quote_requests where id = p_quote_request_id for update;
  select * into v_option from public.quote_options where id = p_option_id and quote_request_id = p_quote_request_id;
  if v_quote.id is null or v_option.id is null then raise exception 'QUOTE_OR_OPTION_NOT_FOUND'; end if;
  if p_decision_type in ('human_confirmed', 'human_override') and v_role not in ('manager', 'admin') then raise exception 'MANAGER_ROLE_REQUIRED'; end if;
  if p_decision_type = 'human_override' and coalesce(trim(p_override_reason), '') = '' then raise exception 'OVERRIDE_REASON_REQUIRED'; end if;
  if exists (select 1 from public.commitments where quote_request_id = p_quote_request_id and status = 'active') then
    select id into v_commitment_id from public.commitments where quote_request_id = p_quote_request_id and status = 'active';
    return v_commitment_id;
  end if;

  insert into public.commitments (
    quote_request_id, quote_option_id, customer_id, material, committed_quantity, promised_delivery_date,
    selling_unit_price, procurement_cost, incremental_cost, projected_margin, decision_type, source_type, created_by
  )
  values (
    v_quote.id, v_option.id, v_quote.customer_id, v_quote.material, v_quote.requested_quantity, v_option.promised_delivery_date,
    v_quote.selling_unit_price, v_option.procurement_cost, v_option.incremental_cost, v_option.projected_margin,
    case when p_decision_type = 'human_override' then 'human_override' when p_decision_type = 'automatic' then 'automatic' else 'human_confirmed' end,
    v_option.sourcing_strategy, v_actor
  )
  returning id into v_commitment_id;

  for v_item in select * from jsonb_array_elements(v_option.allocation_plan) loop
    insert into public.commitment_allocations (commitment_id, source_type, source_po_id, allocated_quantity, availability_date, unit_cost)
    values (
      v_commitment_id,
      v_item->>'source_type',
      nullif(v_item->>'source_po_id', ''),
      (v_item->>'quantity')::numeric,
      (v_item->>'availability_date')::date,
      coalesce((v_item->>'unit_cost')::numeric, 0)
    );
  end loop;

  insert into public.decision_logs (
    quote_request_id, recommended_option_id, selected_option_id, decision_type, deterministic_fallback_reasoning, override_reason,
    threshold_snapshot, actor_id
  )
  values (
    v_quote.id,
    (select id from public.quote_options where quote_request_id = v_quote.id order by threshold_compliant desc, promised_delivery_date, procurement_cost limit 1),
    v_option.id,
    case when p_decision_type = 'human_override' then 'human_override' when p_decision_type = 'automatic' then 'automatic' else 'human_confirmed' end,
    v_option.deterministic_explanation,
    p_override_reason,
    jsonb_build_object('max_delivery_deviation_working_days', public.get_setting_integer('max_delivery_deviation_working_days', 0), 'max_cost_deviation_percentage', public.get_setting_decimal('max_cost_deviation_percentage', 0)),
    v_actor
  );

  update public.quote_requests
  set status = case when p_decision_type = 'automatic' then 'auto_confirmed' when p_decision_type = 'human_override' then 'overridden' else 'human_confirmed' end,
      updated_at = now()
  where id = v_quote.id;

  return v_commitment_id;
end;
$$;

create or replace function public.adjust_inventory(p_material text, p_new_quantity numeric, p_reason text)
returns void language plpgsql security definer set search_path = public, auth as $$
declare
  v_actor uuid := auth.uid();
  v_previous numeric;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.is_manager_or_admin() then raise exception 'MANAGER_ROLE_REQUIRED'; end if;
  if p_new_quantity < 0 or coalesce(trim(p_reason), '') = '' then raise exception 'INVALID_INVENTORY_ADJUSTMENT'; end if;
  select current_stock into v_previous from public.items where material = p_material for update;
  if v_previous is null then raise exception 'UNKNOWN_MATERIAL'; end if;
  update public.items set current_stock = p_new_quantity where material = p_material;
  insert into public.inventory_adjustments (material, previous_quantity, new_quantity, quantity_delta, reason, adjusted_by)
  values (p_material, v_previous, p_new_quantity, p_new_quantity - v_previous, p_reason, v_actor);
end;
$$;

create or replace function public.set_commitment_status(p_commitment_id uuid, p_status text, p_actual_delivery_date date default null)
returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.is_manager_or_admin() then raise exception 'MANAGER_ROLE_REQUIRED'; end if;
  if p_status not in ('delivered', 'cancelled') then raise exception 'INVALID_STATUS'; end if;
  update public.commitments
  set status = p_status,
      actual_delivery_date = case when p_status = 'delivered' then coalesce(p_actual_delivery_date, public.get_operational_date()) else actual_delivery_date end,
      cancelled_at = case when p_status = 'cancelled' then now() else cancelled_at end,
      updated_at = now()
  where id = p_commitment_id;
end;
$$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, auth as $$
begin
  insert into public.profiles (user_id, display_name, role)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', new.email), 'sales')
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

alter table public.vendors enable row level security;
alter table public.items enable row level security;
alter table public.contracts enable row level security;
alter table public.open_pos enable row level security;
alter table public.orders_history enable row level security;
alter table public.customers enable row level security;
alter table public.profiles enable row level security;
alter table public.system_settings enable row level security;
alter table public.vendor_reliability enable row level security;
alter table public.quote_requests enable row level security;
alter table public.quote_options enable row level security;
alter table public.commitments enable row level security;
alter table public.commitment_allocations enable row level security;
alter table public.decision_logs enable row level security;
alter table public.inventory_adjustments enable row level security;

create policy "authenticated read vendors" on public.vendors for select to authenticated using (true);
create policy "authenticated read items" on public.items for select to authenticated using (true);
create policy "authenticated read contracts" on public.contracts for select to authenticated using (true);
create policy "authenticated read open_pos" on public.open_pos for select to authenticated using (true);
create policy "authenticated read orders_history" on public.orders_history for select to authenticated using (true);
create policy "authenticated read customers" on public.customers for select to authenticated using (true);
create policy "authenticated read vendor reliability" on public.vendor_reliability for select to authenticated using (true);
create policy "authenticated read settings" on public.system_settings for select to authenticated using (true);
create policy "admin update settings" on public.system_settings for update to authenticated using (public.current_user_role() = 'admin') with check (public.current_user_role() = 'admin');
create policy "read own profile" on public.profiles for select to authenticated using (user_id = auth.uid() or public.current_user_role() in ('manager', 'admin'));
create policy "admin update profiles" on public.profiles for update to authenticated using (public.current_user_role() = 'admin') with check (public.current_user_role() = 'admin');
create policy "read quote requests" on public.quote_requests for select to authenticated using (created_by = auth.uid() or public.is_manager_or_admin());
create policy "read quote options" on public.quote_options for select to authenticated using (exists (select 1 from public.quote_requests qr where qr.id = quote_request_id and (qr.created_by = auth.uid() or public.is_manager_or_admin())));
create policy "read commitments" on public.commitments for select to authenticated using (true);
create policy "read allocations" on public.commitment_allocations for select to authenticated using (true);
create policy "read decision logs" on public.decision_logs for select to authenticated using (true);
create policy "read inventory adjustments" on public.inventory_adjustments for select to authenticated using (public.is_manager_or_admin());

grant usage on schema public to authenticated;
grant select on public.vendors, public.items, public.contracts, public.open_pos, public.orders_history, public.customers, public.vendor_reliability to authenticated;
grant select on public.current_item_atp, public.open_po_availability, public.dashboard_metrics to authenticated;
grant select on public.profiles, public.system_settings, public.quote_requests, public.quote_options, public.commitments, public.commitment_allocations, public.decision_logs, public.inventory_adjustments to authenticated;
grant execute on function public.calculate_ctp_options(text, text, numeric, numeric, text) to authenticated;
grant execute on function public.confirm_quote_option(uuid, uuid, text, text) to authenticated;
grant execute on function public.adjust_inventory(text, numeric, text) to authenticated;
grant execute on function public.set_commitment_status(uuid, text, date) to authenticated;
