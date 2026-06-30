import { useEffect, useMemo, useState } from 'react'
import { BrowserRouter, NavLink, Route, Routes, useNavigate, useParams } from 'react-router-dom'
import { QueryClient, QueryClientProvider, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import type { Session } from '@supabase/supabase-js'
import { BarChart3, Boxes, Check, ClipboardList, Clock, LogOut, PackageCheck, PackagePlus, ReceiptText, Settings, ShieldCheck, Truck } from 'lucide-react'
import { supabase } from './lib/supabase'
import { money, number, pct } from './lib/format'
import './App.css'

type Role = 'sales' | 'manager' | 'admin'
type Profile = { user_id: string; display_name: string | null; role: Role }
type Item = { material: string; description: string; current_stock: number; avg_daily_demand: number | null }
type Customer = { customer_id: string; customer_name: string | null; customer_tier: string }
type QuoteRequest = {
  id: string
  customer_id: string
  customer_tier_snapshot: string
  material: string
  requested_quantity: number
  selling_unit_price: number
  status: string
  requested_at: string
  response_time_ms: number | null
  recommended_option_id?: string | null
  recommendation_source?: string | null
  recommendation_text?: string | null
  recommendation_reasoning?: string | null
  recommendation_main_risk?: string | null
  recommendation_confidence?: number | null
  escalation_reason?: string | null
}
type QuoteOption = {
  id: string
  quote_request_id: string
  option_label: string
  sourcing_strategy: string
  promised_delivery_date: string
  procurement_cost: number
  incremental_cost: number
  projected_margin: number
  margin_percentage: number
  threshold_compliant: boolean
  is_expedited?: boolean
  allocation_plan?: unknown
  deterministic_explanation: string
}
type AnyRow = Record<string, string | number | boolean | null>

const queryClient = new QueryClient()

function useSession() {
  const [session, setSession] = useState<Session | null>(null)
  const [loading, setLoading] = useState(true)
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      setLoading(false)
    })
    const { data } = supabase.auth.onAuthStateChange((_event, nextSession) => setSession(nextSession))
    return () => data.subscription.unsubscribe()
  }, [])
  return { session, loading }
}

async function rows<T>(table: string, columns = '*') {
  const { data, error } = await supabase.from(table).select(columns)
  if (error) throw error
  return data as T[]
}

function readableError(error: unknown) {
  const message = error instanceof Error ? error.message : String(error)
  if (message.includes('STALE_QUOTE')) {
    return 'Availability has changed since this quotation was calculated. Please recalculate the delivery promise.'
  }
  return message
}

function useProfile(session: Session) {
  return useQuery({
    queryKey: ['profile', session.user.id],
    queryFn: async () => {
      const { data, error } = await supabase.from('profiles').select('*').eq('user_id', session.user.id).single()
      if (error) throw error
      return data as Profile
    },
  })
}

function SignIn() {
  const [error, setError] = useState<string | null>(null)
  const form = useForm<{ email: string; password: string }>()
  return (
    <main className="signin">
      <form className="signin-panel" onSubmit={form.handleSubmit(async (values) => {
        setError(null)
        const { error: authError } = await supabase.auth.signInWithPassword(values)
        if (authError) setError(authError.message)
      })}>
        <div className="brand large"><span>GC</span><strong>GrainCraft CTP</strong></div>
        <h1>Sign in</h1>
        <label>Email<input type="email" {...form.register('email', { required: true })} /></label>
        <label>Password<input type="password" {...form.register('password', { required: true })} /></label>
        {error && <p className="error">{error}</p>}
        <button type="submit" disabled={form.formState.isSubmitting}>Sign in</button>
      </form>
    </main>
  )
}

function Shell({ session }: { session: Session }) {
  const profile = useProfile(session)
  const nav = [
    ['/', 'Dashboard', BarChart3],
    ['/quote/new', 'New Quote', PackagePlus],
    ['/review', 'Review', ShieldCheck],
    ['/inventory', 'Inventory', Boxes],
    ['/purchase-orders', 'Purchase Orders', Truck],
    ['/commitments', 'Commitments', PackageCheck],
    ['/history', 'Decision History', ClipboardList],
    ['/email-preview', 'Email Preview', ReceiptText],
    ['/settings', 'Settings', Settings],
  ] as const
  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand"><span>GC</span><div><strong>GrainCraft CTP</strong><small>{profile.data?.role ?? 'sales'} workspace</small></div></div>
        <nav>{nav.map(([href, label, Icon]) => <NavLink key={href} to={href} end={href === '/'}><Icon size={18} />{label}</NavLink>)}</nav>
        <button className="ghost full" type="button" onClick={() => supabase.auth.signOut()}><LogOut size={17} /> Sign out</button>
      </aside>
      <main className="content">
        <Routes>
          <Route path="/" element={<Dashboard />} />
          <Route path="/quote/new" element={<NewQuote />} />
          <Route path="/quote/:id" element={<QuoteResult />} />
          <Route path="/review" element={<ReviewQueue />} />
          <Route path="/inventory" element={<Inventory role={profile.data?.role} />} />
          <Route path="/purchase-orders" element={<PurchaseOrders />} />
          <Route path="/commitments" element={<Commitments role={profile.data?.role} />} />
          <Route path="/history" element={<DecisionHistory />} />
          <Route path="/email-preview" element={<EmailPreview />} />
          <Route path="/settings" element={<SettingsPage role={profile.data?.role} />} />
          <Route path="*" element={<Page title="Unauthorized" kicker="Access"><p className="muted">This route is not available.</p></Page>} />
        </Routes>
      </main>
    </div>
  )
}

function Dashboard() {
  const metrics = useQuery({ queryKey: ['dashboard'], queryFn: async () => (await rows<AnyRow>('dashboard_metrics'))[0] })
  const atp = useQuery({ queryKey: ['atp'], queryFn: () => rows<AnyRow>('current_item_atp') })
  const pos = useQuery({ queryKey: ['purchase-orders'], queryFn: () => rows<AnyRow>('open_po_availability') })
  const decisions = useQuery({ queryKey: ['decisions'], queryFn: () => rows<AnyRow>('decision_logs').then((data) => data.slice(-8).reverse()) })
  const m = metrics.data
  const lowCoverage = (atp.data ?? []).filter((row) => Number(row.stock_coverage_days ?? 999) < 3)
  const overdue = (pos.data ?? []).filter((row) => row.overdue)
  return (
    <Page title="Dashboard" kicker="Operations control tower">
      <div className="metric-grid">
        <Metric label="Quotes today" value={number(m?.quotations_processed_today as number)} />
        <Metric label="Auto confirmed" value={number(m?.automatically_confirmed_quotations as number)} />
        <Metric label="Pending review" value={number(m?.pending_review_quotations as number)} />
        <Metric label="Automation rate" value={pct(m?.automation_rate as number)} />
        <Metric label="Avg response" value={`${number(m?.average_response_time_ms as number)} ms`} />
        <Metric label="Delivery accuracy" value={pct(m?.delivery_accuracy as number)} />
        <Metric label="Expedite cost" value={money(m?.total_expedite_incremental_cost as number)} />
      </div>
      <div className="grid two">
        <Table title="Stock Coverage" rows={atp.data ?? []} columns={['material', 'description', 'free_stock_quantity', 'stock_coverage_days', 'next_expected_availability_date']} />
        <Table title="Low Coverage Alerts" rows={lowCoverage} columns={['material', 'description', 'free_stock_quantity', 'stock_coverage_days']} />
        <Table title="Overdue POs" rows={overdue} columns={['po_id', 'material', 'unallocated_quantity', 'expected_delivery_date', 'status']} />
        <Table title="Recent Decisions" rows={decisions.data ?? []} columns={['decision_type', 'quote_request_id', 'selected_option_id', 'created_at']} />
      </div>
    </Page>
  )
}

function Metric({ label, value }: { label: string; value: string }) {
  return <div className="metric"><small>{label}</small><strong>{value}</strong></div>
}

const quoteSchema = z.object({
  customer_id: z.string().min(1),
  material: z.string().min(1),
  requested_quantity: z.coerce.number().positive(),
  selling_unit_price: z.coerce.number().positive(),
})

function NewQuote() {
  const navigate = useNavigate()
  const customers = useQuery({ queryKey: ['customers'], queryFn: () => rows<Customer>('customers') })
  const items = useQuery({ queryKey: ['items'], queryFn: () => rows<Item>('items') })
  const form = useForm<z.input<typeof quoteSchema>>({ resolver: zodResolver(quoteSchema) })
  const customerId = useWatch({ control: form.control, name: 'customer_id' })
  const material = useWatch({ control: form.control, name: 'material' })
  const selectedCustomer = customers.data?.find((customer) => customer.customer_id === customerId)
  const selectedItem = items.data?.find((item) => item.material === material)
  const calculate = useMutation({
    mutationFn: async (values: z.infer<typeof quoteSchema>) => {
      const { data, error } = await supabase.rpc('calculate_ctp_options', {
        p_customer_id: values.customer_id,
        p_material: values.material,
        p_requested_quantity: values.requested_quantity,
        p_selling_unit_price: values.selling_unit_price,
        p_idempotency_key: crypto.randomUUID(),
      })
      if (error) throw error
      return data as { quote_request_id: string }[]
    },
    onSuccess: (data) => navigate(`/quote/${data[0]?.quote_request_id}`),
  })
  return (
    <Page title="New Quote" kicker="Calculate delivery promise">
      <form className="quote-form" onSubmit={form.handleSubmit((values) => calculate.mutate(quoteSchema.parse(values)))}>
        <label>Customer<select {...form.register('customer_id')}><option value="">Select customer</option>{customers.data?.map((customer) => <option key={customer.customer_id} value={customer.customer_id}>{customer.customer_name ?? customer.customer_id}</option>)}</select></label>
        <p className="field-note">Tier: {selectedCustomer?.customer_tier ?? 'N/A'}</p>
        <label>Material<select {...form.register('material')}><option value="">Select SKU</option>{items.data?.map((item) => <option key={item.material} value={item.material}>{item.material} - {item.description}</option>)}</select></label>
        <p className="field-note">Stock: {number(selectedItem?.current_stock)} | Demand/day: {number(selectedItem?.avg_daily_demand, 1)}</p>
        <label>Requested quantity<input type="number" step="0.01" {...form.register('requested_quantity')} /></label>
        <label>Selling unit price<input type="number" step="0.0001" {...form.register('selling_unit_price')} /></label>
        {calculate.error && <p className="error">{calculate.error.message}</p>}
        <button type="submit" disabled={calculate.isPending}>Calculate delivery promise</button>
      </form>
    </Page>
  )
}

function QuoteResult() {
  const { id } = useParams()
  const queryClient = useQueryClient()
  const quote = useQuery({ queryKey: ['quote', id], queryFn: async () => (await supabase.from('quote_requests').select('*').eq('id', id).single()).data as QuoteRequest })
  const options = useQuery({ queryKey: ['quote-options', id], queryFn: async () => (await supabase.from('quote_options').select('*').eq('quote_request_id', id).order('promised_delivery_date')).data as QuoteOption[] })
  const commitments = useQuery({ queryKey: ['quote-commitments', id], queryFn: async () => (await supabase.from('commitments').select('*').eq('quote_request_id', id).order('confirmed_at', { ascending: false })).data as AnyRow[] })
  const atp = useQuery({ queryKey: ['atp'], queryFn: () => rows<AnyRow>('current_item_atp') })
  const pos = useQuery({ queryKey: ['purchase-orders'], queryFn: () => rows<AnyRow>('open_po_availability') })
  const settings = useQuery({ queryKey: ['settings'], queryFn: () => rows<AnyRow>('system_settings') })
  const customerHistory = useQuery({
    queryKey: ['customer-history', quote.data?.customer_id],
    enabled: Boolean(quote.data?.customer_id && quote.data.status === 'pending_review'),
    queryFn: async () => {
      const { data, error } = await supabase
        .from('orders_history')
        .select('quantity, unit_price_charged, actual_delivery_date, promised_date, expedite_used')
        .eq('customer_id', quote.data!.customer_id)
      if (error) throw error
      return data as Array<{ quantity: number | null; unit_price_charged: number | null; actual_delivery_date: string | null; promised_date: string | null; expedite_used: boolean | null }>
    },
  })
  const vendorReliability = useQuery({ queryKey: ['vendor-reliability'], queryFn: () => rows<AnyRow>('vendor_reliability') })
  const [selectedOptionId, setSelectedOptionId] = useState<string>('')
  const [overrideReason, setOverrideReason] = useState('')
  const stock = atp.data?.find((row) => row.material === quote.data?.material)
  const relevantPos = (pos.data ?? []).filter((row) => row.material === quote.data?.material)
  const commitment = commitments.data?.find((row) => ['active', 'delivered'].includes(String(row.status))) ?? commitments.data?.[0]
  const commitmentAllocations = useQuery({
    queryKey: ['quote-commitment-allocations', commitment?.id],
    enabled: Boolean(commitment?.id),
    queryFn: async () => (await supabase.from('commitment_allocations').select('*').eq('commitment_id', commitment!.id)).data as AnyRow[],
  })
  const finalStatuses = ['auto_confirmed', 'human_confirmed', 'overridden']
  const isFinal = Boolean(commitment?.id && quote.data && finalStatuses.includes(quote.data.status))
  const confirmedOptionId = String(commitment?.quote_option_id ?? '')

  const aiRec = useQuery({
    queryKey: ['ai-rec', id],
    enabled: Boolean(quote.data?.status === 'pending_review' && options.data?.length),
    staleTime: Infinity,
    queryFn: async () => {
      if (quote.data?.recommendation_reasoning) return {
        recommended_option_id: quote.data.recommended_option_id,
        reasoning: quote.data.recommendation_reasoning,
        main_risk: quote.data.recommendation_main_risk,
        confidence: quote.data.recommendation_confidence,
      }
      const history = customerHistory.data ?? []
      const historicalTotalValue = history.length ? history.reduce((s, r) => s + (Number(r.quantity) || 0) * (Number(r.unit_price_charged) || 0), 0) : null
      const delivered = history.filter(r => r.actual_delivery_date && r.promised_date)
      const historicalDeliveryPerformance = delivered.length ? delivered.filter(r => r.actual_delivery_date! <= r.promised_date!).length / delivered.length : null
      const historicalExpediteUsage = history.length ? history.filter(r => r.expedite_used).length / history.length : null
      const { data, error } = await supabase.functions.invoke('ctp-recommendation', {
        body: {
          quote_request: quote.data,
          customer_tier: quote.data?.customer_tier_snapshot,
          historical_customer_order_value: historicalTotalValue,
          historical_delivery_performance: historicalDeliveryPerformance,
          historical_expedite_usage: historicalExpediteUsage,
          current_stock: stock,
          open_pos: relevantPos,
          supplier_reliability: vendorReliability.data ?? null,
          options: options.data,
          thresholds: settings.data,
          escalation_reason: quote.data?.escalation_reason,
        },
      })
      if (error || !data?.recommended_option_id) throw new Error('Recommendation unavailable')
      void supabase.rpc('persist_quote_recommendation', {
        p_quote_request_id: quote.data!.id,
        p_recommended_option_id: data.recommended_option_id,
        p_source: 'llm',
        p_recommendation: data.recommendation,
        p_reasoning: data.reasoning,
        p_main_risk: data.main_risk,
        p_confidence: data.confidence,
      })
      return data
    },
  })

  const confirm = useMutation({
    mutationFn: async (option: QuoteOption) => {
      const recommendedId = quote.data?.recommended_option_id ?? options.data?.[0]?.id
      const isOverride = Boolean(recommendedId && option.id !== recommendedId)
      if (isOverride && overrideReason.trim().length < 6) throw new Error('Enter an override reason before selecting a non-recommended option.')
      const { error } = await supabase.rpc('confirm_quote_option', {
        p_quote_request_id: id,
        p_option_id: option.id,
        p_decision_type: isOverride ? 'human_override' : 'human_confirmed',
        p_override_reason: isOverride ? overrideReason.trim() : null,
      })
      if (error) throw error
    },
    onSuccess: () => queryClient.invalidateQueries(),
  })
  const recommendedId = quote.data?.recommended_option_id ?? options.data?.find((option) => option.threshold_compliant)?.id ?? options.data?.[0]?.id
  const confirmedOption = options.data?.find((option) => option.id === confirmedOptionId)
  const alternatives = (options.data ?? []).filter((option) => option.id !== confirmedOptionId)
  return (
    <Page title="Quote Result" kicker={quote.data ? `${quote.data.customer_id} | ${quote.data.material} | ${number(quote.data.requested_quantity)} units` : 'Loading'}>
      <div className="metric-grid">
        <Metric label="Physical stock" value={number(stock?.current_stock as number)} />
        <Metric label="Free ATP" value={number(stock?.free_stock_quantity as number)} />
        <Metric label="Status" value={quote.data?.status ?? 'N/A'} />
        <Metric label="Response" value={`${number(quote.data?.response_time_ms)} ms`} />
      </div>
      {isFinal && (
        <section className="success-banner">
          <div>
            <h2>Delivery promise confirmed</h2>
            <p>{number(commitment?.committed_quantity as number)} units confirmed from {humanStrategy(String(commitment?.source_type))}.</p>
          </div>
          <dl>
            <div><dt>Commitment reference</dt><dd>{String(commitment?.id)}</dd></div>
            <div><dt>Confirmation timestamp</dt><dd>{String(commitment?.confirmed_at ?? 'N/A')}</dd></div>
            <div><dt>Confirmed option</dt><dd>{confirmedOption?.option_label ?? confirmedOptionId}</dd></div>
            <div><dt>Promised delivery date</dt><dd>{String(commitment?.promised_delivery_date)}</dd></div>
            <div><dt>Total selling value</dt><dd>{money(Number(commitment?.committed_quantity ?? 0) * Number(commitment?.selling_unit_price ?? 0))}</dd></div>
            <div><dt>Procurement cost</dt><dd>{money(commitment?.procurement_cost as number)}</dd></div>
            <div><dt>Projected margin</dt><dd>{money(commitment?.projected_margin as number)}</dd></div>
          </dl>
          <AllocationSummary rows={allocationRowsFromCommitment(commitmentAllocations.data ?? [])} />
          <button type="button" onClick={() => { window.location.href = '/commitments' }}>Open commitment detail</button>
        </section>
      )}
      {(aiRec.data || aiRec.isPending || quote.data?.recommendation_reasoning) && (
        <section className="review-panel">
          <h2>AI Recommendation</h2>
          {aiRec.isPending && !quote.data?.recommendation_reasoning && <p className="muted">Generating recommendation…</p>}
          <p className="muted">{aiRec.data?.reasoning ?? quote.data?.recommendation_reasoning ?? ''}</p>
          {(aiRec.data?.main_risk ?? quote.data?.recommendation_main_risk) && <p><strong>Main risk:</strong> {aiRec.data?.main_risk ?? quote.data?.recommendation_main_risk}</p>}
          {(aiRec.data?.confidence ?? quote.data?.recommendation_confidence) != null && <p><strong>Confidence:</strong> {pct(aiRec.data?.confidence ?? quote.data?.recommendation_confidence)}</p>}
          {!isFinal && <label>Override reason<input value={overrideReason} onChange={(event) => setOverrideReason(event.target.value)} placeholder="Required when selecting a non-recommended option" /></label>}
        </section>
      )}
      {isFinal && confirmedOption && <OptionCard option={confirmedOption} badge="Confirmed option" readonly />}
      {isFinal && alternatives.length > 0 && (
        <details className="alternatives">
          <summary>Alternative options considered</summary>
          <div className="options-grid">{alternatives.map((option) => <OptionCard key={option.id} option={option} badge="Read-only alternative" readonly />)}</div>
        </details>
      )}
      {!isFinal && (
        <div className="options-grid">
          {options.data?.map((option) => (
            <OptionCard
              key={option.id}
              option={option}
              badge={option.id === recommendedId ? 'Recommended' : 'Alternative'}
              selected={selectedOptionId === option.id}
              onSelect={() => setSelectedOptionId(option.id)}
              onConfirm={() => confirm.mutate(option)}
              confirmDisabled={confirm.isPending}
            />
          ))}
        </div>
      )}
      {confirm.error && <p className="error">{readableError(confirm.error)}</p>}
    </Page>
  )
}

function OptionCard({
  option,
  badge,
  readonly = false,
  selected = false,
  onSelect,
  onConfirm,
  confirmDisabled,
}: {
  option: QuoteOption
  badge: string
  readonly?: boolean
  selected?: boolean
  onSelect?: () => void
  onConfirm?: () => void
  confirmDisabled?: boolean
}) {
  return (
    <article className="option-card">
      <div className="option-head"><strong>{option.option_label}</strong><span className={badge === 'Confirmed option' ? 'pill good' : 'pill warn'}>{badge}</span></div>
      <dl>
        <div><dt>Promise date</dt><dd>{option.promised_delivery_date}</dd></div>
        <div><dt>Strategy</dt><dd>{humanStrategy(option.sourcing_strategy)}</dd></div>
        <div><dt>Procurement</dt><dd>{money(option.procurement_cost)}</dd></div>
        <div><dt>Incremental</dt><dd>{money(option.incremental_cost)}</dd></div>
        <div><dt>Margin</dt><dd>{money(option.projected_margin)} ({number(option.margin_percentage, 1)}%)</dd></div>
      </dl>
      <p>{option.deterministic_explanation}</p>
      <AllocationSummary rows={allocationRowsFromPlan(option.allocation_plan)} />
      <details>
        <summary>Technical allocation JSON</summary>
        <pre className="allocation-plan">{JSON.stringify(option.allocation_plan ?? [], null, 2)}</pre>
      </details>
      {!readonly && (
        <>
          <label><input type="radio" checked={selected} onChange={onSelect} /> Select option</label>
          <button type="button" onClick={onConfirm} disabled={confirmDisabled}><Check size={16} /> Confirm option</button>
        </>
      )}
    </article>
  )
}

function AllocationSummary({ rows }: { rows: AnyRow[] }) {
  return (
    <section className="allocation-summary">
      <h3>Allocation summary</h3>
      <table>
        <thead><tr><th>Source</th><th>Vendor or PO reference</th><th>Quantity</th><th>Availability date</th><th>Unit cost</th></tr></thead>
        <tbody>
          {rows.map((row, index) => (
            <tr key={`${row.reference}-${index}`}>
              <td>{row.source}</td>
              <td>{row.reference}</td>
              <td>{number(row.quantity as number, 2)}</td>
              <td>{row.availability_date}</td>
              <td>{money(row.unit_cost as number)}</td>
            </tr>
          ))}
          {rows.length === 0 && <tr><td colSpan={5}>No allocation rows found.</td></tr>}
        </tbody>
      </table>
    </section>
  )
}

function allocationRowsFromCommitment(rows: AnyRow[]): AnyRow[] {
  return rows.map((row) => ({
    source: humanStrategy(String(row.source_type ?? '')),
    reference: String(row.source_po_id ?? (row.source_type === 'stock' ? 'Current stock' : 'N/A')),
    quantity: Number(row.allocated_quantity ?? 0),
    availability_date: String(row.availability_date ?? 'N/A'),
    unit_cost: Number(row.unit_cost ?? 0),
  }))
}

function allocationRowsFromPlan(plan: unknown): AnyRow[] {
  if (!Array.isArray(plan)) return []
  return plan.map((item) => {
    const row = item as Record<string, unknown>
    return {
      source: humanStrategy(String(row.source_type ?? '')),
      reference: String(row.source_po_id ?? row.vendor_code ?? 'Current stock'),
      quantity: Number(row.quantity ?? 0),
      availability_date: String(row.availability_date ?? 'N/A'),
      unit_cost: Number(row.unit_cost ?? 0),
    }
  })
}

function humanStrategy(value: string) {
  return value.replaceAll('_', ' ')
}

function ReviewQueue() {
  const quotes = useQuery({ queryKey: ['review'], queryFn: async () => (await supabase.from('quote_requests').select('*').eq('status', 'pending_review').order('requested_at')).data as QuoteRequest[] })
  return <Page title="Human Review Queue" kicker="Pending recommendations"><Table rows={quotes.data ?? []} columns={['customer_id', 'material', 'requested_quantity', 'selling_unit_price', 'status', 'requested_at']} linkPrefix="/quote/" linkKey="id" /></Page>
}

function Inventory({ role }: { role?: Role }) {
  const queryClient = useQueryClient()
  const atp = useQuery({ queryKey: ['atp'], queryFn: () => rows<AnyRow>('current_item_atp') })
  const [draft, setDraft] = useState({ material: '', quantity: '', reason: '' })
  const adjust = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc('adjust_inventory', { p_material: draft.material, p_new_quantity: Number(draft.quantity), p_reason: draft.reason })
      if (error) throw error
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['atp'] }),
  })
  return (
    <Page title="Inventory and ATP" kicker="Time-phased availability">
      <Table rows={atp.data ?? []} columns={['material', 'description', 'current_stock', 'active_stock_allocation_quantity', 'free_stock_quantity', 'avg_daily_demand', 'stock_coverage_days', 'incoming_po_quantity', 'allocated_po_quantity', 'overdue_po_quantity', 'next_expected_availability_date']} />
      {['manager', 'admin'].includes(role ?? 'sales') && <form className="inline-form" onSubmit={(event) => { event.preventDefault(); adjust.mutate() }}><input placeholder="Material" value={draft.material} onChange={(event) => setDraft({ ...draft, material: event.target.value })} /><input placeholder="New quantity" type="number" value={draft.quantity} onChange={(event) => setDraft({ ...draft, quantity: event.target.value })} /><input placeholder="Reason" value={draft.reason} onChange={(event) => setDraft({ ...draft, reason: event.target.value })} /><button type="submit">Adjust inventory</button></form>}
      {adjust.error && <p className="error">{adjust.error.message}</p>}
    </Page>
  )
}

function PurchaseOrders() {
  const pos = useQuery({ queryKey: ['purchase-orders'], queryFn: () => rows<AnyRow>('open_po_availability') })
  return <Page title="Purchase Orders" kicker="Imported and allocated supply"><Table rows={pos.data ?? []} columns={['po_id', 'vendor_name', 'material', 'quantity_ordered', 'quantity_received', 'remaining_quantity', 'allocated_quantity', 'unallocated_quantity', 'expected_delivery_date', 'buffered_availability_date', 'overdue', 'status']} /></Page>
}

function Commitments({ role }: { role?: Role }) {
  const queryClient = useQueryClient()
  const commitments = useQuery({ queryKey: ['commitments'], queryFn: () => rows<AnyRow>('commitments') })
  const allocations = useQuery({ queryKey: ['allocations'], queryFn: () => rows<AnyRow>('commitment_allocations') })
  const [actualDate, setActualDate] = useState('')
  const [cancelReason, setCancelReason] = useState('')
  const update = useMutation({
    mutationFn: async ({ id, status }: { id: string; status: 'delivered' | 'cancelled' }) => {
      const { error } = await supabase.rpc('set_commitment_status', {
        p_commitment_id: id,
        p_status: status,
        p_actual_delivery_date: status === 'delivered' ? actualDate || null : null,
        p_cancellation_reason: status === 'cancelled' ? cancelReason : null,
      })
      if (error) throw error
    },
    onSuccess: () => queryClient.invalidateQueries(),
  })
  const canAct = ['manager', 'admin'].includes(role ?? 'sales')
  return (
    <Page title="Commitments" kicker="Active, delivered, and cancelled promises">
      <div className="commitment-list">
        {(commitments.data ?? []).map((commitment) => (
          <article className="option-card" key={String(commitment.id)}>
            <div className="option-head"><strong>{commitment.customer_id} | {commitment.material}</strong><span className="pill good">{String(commitment.status)}</span></div>
            <dl>
              <div><dt>Quantity</dt><dd>{number(commitment.committed_quantity as number)}</dd></div>
              <div><dt>Promise</dt><dd>{String(commitment.promised_delivery_date)}</dd></div>
              <div><dt>Decision</dt><dd>{String(commitment.decision_type)}</dd></div>
              <div><dt>Margin</dt><dd>{money(commitment.projected_margin as number)}</dd></div>
            </dl>
            <Table rows={(allocations.data ?? []).filter((row) => row.commitment_id === commitment.id)} columns={['source_type', 'source_po_id', 'allocated_quantity', 'availability_date', 'unit_cost']} />
            {canAct && commitment.status === 'active' && (
              <div className="inline-form">
                <input type="date" value={actualDate} onChange={(event) => setActualDate(event.target.value)} aria-label="Actual delivery date" />
                <button type="button" onClick={() => update.mutate({ id: String(commitment.id), status: 'delivered' })}>Mark delivered</button>
                <input value={cancelReason} onChange={(event) => setCancelReason(event.target.value)} placeholder="Cancellation reason" />
                <button type="button" onClick={() => update.mutate({ id: String(commitment.id), status: 'cancelled' })}>Cancel</button>
              </div>
            )}
          </article>
        ))}
      </div>
      {commitments.data?.length === 0 && <p className="muted">No commitments found.</p>}
      {update.error && <p className="error">{readableError(update.error)}</p>}
    </Page>
  )
}

function DecisionHistory() {
  const logs = useQuery({ queryKey: ['decision-history'], queryFn: () => rows<AnyRow>('decision_logs') })
  return <Page title="Decision History" kicker="Automatic, confirmed, and override decisions"><Table rows={logs.data ?? []} columns={['decision_type', 'quote_request_id', 'recommended_option_id', 'selected_option_id', 'override_reason', 'actor_id', 'created_at']} /></Page>
}

function SettingsPage({ role }: { role?: Role }) {
  const queryClient = useQueryClient()
  const settings = useQuery({ queryKey: ['settings'], queryFn: () => rows<AnyRow>('system_settings') })
  return (
    <Page title="Settings" kicker={role === 'admin' ? 'Editable operating policy' : 'Read-only operating policy'}>
      <div className="settings-list">
        {(settings.data ?? []).map((setting) => <SettingEditor key={String(setting.setting_key)} setting={setting} canEdit={role === 'admin'} onSaved={() => queryClient.invalidateQueries({ queryKey: ['settings'] })} />)}
      </div>
    </Page>
  )
}

const settingSchema = z.object({
  boolean_value: z.boolean().nullable().optional(),
  date_value: z.string().nullable().optional(),
  integer_value: z.coerce.number().int().nullable().optional(),
  decimal_value: z.coerce.number().nullable().optional(),
  text_value: z.string().nullable().optional(),
})

function SettingEditor({ setting, canEdit, onSaved }: { setting: AnyRow; canEdit: boolean; onSaved: () => void }) {
  const [draft, setDraft] = useState(() => ({
    boolean_value: setting.boolean_value === true,
    date_value: String(setting.date_value ?? ''),
    integer_value: String(setting.integer_value ?? ''),
    decimal_value: String(setting.decimal_value ?? ''),
    text_value: String(setting.text_value ?? ''),
  }))
  const save = useMutation({
    mutationFn: async () => {
      const parsed = settingSchema.parse({
        boolean_value: draft.boolean_value,
        date_value: draft.date_value || null,
        integer_value: draft.integer_value === '' ? null : Number(draft.integer_value),
        decimal_value: draft.decimal_value === '' ? null : Number(draft.decimal_value),
        text_value: draft.text_value || null,
      })
      const { error } = await supabase.rpc('update_system_setting', {
        p_setting_key: setting.setting_key,
        p_boolean_value: parsed.boolean_value,
        p_date_value: parsed.date_value,
        p_integer_value: parsed.integer_value,
        p_decimal_value: parsed.decimal_value,
        p_text_value: parsed.text_value,
      })
      if (error) throw error
    },
    onSuccess: onSaved,
  })
  return (
    <article className="setting-row">
      <div><strong>{setting.setting_key}</strong><p className="muted">{setting.description} {setting.unit ? `(${setting.unit})` : ''}</p></div>
      {setting.setting_type === 'boolean' && <input type="checkbox" checked={draft.boolean_value} disabled={!canEdit} onChange={(event) => setDraft({ ...draft, boolean_value: event.target.checked })} />}
      {setting.setting_type === 'date' && <input type="date" value={draft.date_value} disabled={!canEdit} onChange={(event) => setDraft({ ...draft, date_value: event.target.value })} />}
      {setting.setting_type === 'integer' && <input type="number" value={draft.integer_value} disabled={!canEdit} onChange={(event) => setDraft({ ...draft, integer_value: event.target.value })} />}
      {setting.setting_type === 'decimal' && <input type="number" step="0.0001" value={draft.decimal_value} disabled={!canEdit} onChange={(event) => setDraft({ ...draft, decimal_value: event.target.value })} />}
      {setting.setting_type === 'text' && <input value={draft.text_value} disabled={!canEdit} onChange={(event) => setDraft({ ...draft, text_value: event.target.value })} />}
      {canEdit && <button type="button" onClick={() => save.mutate()} disabled={save.isPending}>Save</button>}
      {save.error && <p className="error">{readableError(save.error)}</p>}
    </article>
  )
}

function EmailPreview() {
  const commitments = useQuery({ queryKey: ['confirmed-commitments'], queryFn: async () => (await supabase.from('commitments').select('*').in('status', ['active', 'delivered']).order('confirmed_at', { ascending: false }).limit(1)).data as AnyRow[] })
  const items = useQuery({ queryKey: ['items'], queryFn: () => rows<Item>('items') })
  const commitment = commitments.data?.[0]
  const item = items.data?.find((row) => row.material === commitment?.material)
  const expediteNote = ['fast_track', 'air_freight'].includes(String(commitment?.source_type)) ? '\n\nThis promise uses expedited sourcing.' : ''
  const body = commitment ? `Dear ${commitment.customer_id},\n\nWe can confirm ${number(commitment.committed_quantity as number)} units of ${commitment.material} (${item?.description ?? 'product'}) at ${money(commitment.selling_unit_price as number)} per unit.\n\nPromised delivery date: ${commitment.promised_delivery_date}\nTotal value: ${money(Number(commitment.committed_quantity) * Number(commitment.selling_unit_price))}${expediteNote}\n\nRegards,\nGrainCraft Foods` : 'No confirmed commitment is available yet.'
  return <Page title="Email Preview" kicker="Plain-text quotation draft"><pre className="email-preview">{body}</pre></Page>
}

function Page({ title, kicker, children }: { title: string; kicker: string; children: React.ReactNode }) {
  return <section className="page"><header><span>{kicker}</span><h1>{title}</h1></header>{children}</section>
}

function Table({ title, rows: data, columns, linkPrefix, linkKey }: { title?: string; rows: AnyRow[]; columns: string[]; linkPrefix?: string; linkKey?: string }) {
  return (
    <section className="table-wrap">
      {title && <h2>{title}</h2>}
      <div className="table-scroll">
        <table>
          <thead><tr>{columns.map((col) => <th key={col}>{col.replaceAll('_', ' ')}</th>)}</tr></thead>
          <tbody>
            {data.map((row, index) => <tr key={String(row.id ?? index)} onClick={() => linkPrefix && linkKey && (window.location.href = `${linkPrefix}${String(row[linkKey])}`)}>{columns.map((col) => <td key={col}>{cell(row[col])}</td>)}</tr>)}
            {data.length === 0 && <tr><td colSpan={columns.length}>No records found.</td></tr>}
          </tbody>
        </table>
      </div>
    </section>
  )
}

function cell(value: unknown) {
  if (value === null || value === undefined) return 'N/A'
  if (typeof value === 'boolean') return value ? 'Yes' : 'No'
  if (typeof value === 'number') return number(value, 2)
  return String(value)
}

function AppRoot() {
  const { session, loading } = useSession()
  const content = useMemo(() => {
    if (loading) return <main className="loading"><Clock /> Loading</main>
    return session ? <Shell session={session} /> : <SignIn />
  }, [loading, session])
  return <BrowserRouter>{content}</BrowserRouter>
}

export default function App() {
  return <QueryClientProvider client={queryClient}><AppRoot /></QueryClientProvider>
}
