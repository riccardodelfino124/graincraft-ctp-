type Option = {
  id: string
  sourcing_strategy: string
  promised_delivery_date: string
  procurement_cost: number
  incremental_cost: number
  projected_margin: number
  threshold_compliant: boolean
}

type Recommendation = {
  recommended_option_id: string
  recommendation: 'USE_STANDARD' | 'USE_EXISTING_PO' | 'USE_FAST_TRACK' | 'USE_AIR_FREIGHT'
  reasoning: string
  main_risk: string
  confidence: number
}

function strategyCode(s: string): Recommendation['recommendation'] {
  if (s === 'existing_open_po' || s === 'stock_plus_open_po') return 'USE_EXISTING_PO'
  if (s === 'fast_track') return 'USE_FAST_TRACK'
  if (s === 'air_freight') return 'USE_AIR_FREIGHT'
  return 'USE_STANDARD'
}

function recommend(options: Option[], payload: Record<string, unknown>): Recommendation {
  const sorted = [...options].sort((a, b) => {
    if (a.threshold_compliant !== b.threshold_compliant) return a.threshold_compliant ? -1 : 1
    if (a.promised_delivery_date !== b.promised_delivery_date) return a.promised_delivery_date.localeCompare(b.promised_delivery_date)
    return Number(a.procurement_cost) - Number(b.procurement_cost)
  })
  const option = sorted[0]
  if (!option) return { recommended_option_id: '', recommendation: 'USE_STANDARD', reasoning: 'No options available.', main_risk: 'No options to evaluate.', confidence: 0 }

  const tier = String(payload.customer_tier ?? 'standard').toLowerCase()
  const cost = Number(option.procurement_cost)
  const margin = Number(option.projected_margin)
  const incremental = Number(option.incremental_cost)
  const deliveryPerf = Number(payload.historical_delivery_performance ?? 1)
  const expediteUsage = Number(payload.historical_expedite_usage ?? 0)
  const reliability = payload.supplier_reliability as Record<string, number> | null

  const tierLabel = tier === 'gold' ? 'gold-tier' : tier === 'silver' ? 'silver-tier' : 'standard'
  const marginPct = cost > 0 ? Math.round((margin / (margin + cost)) * 100) : 0

  const strategyLabel: Record<string, string> = {
    existing_open_po: 'an existing open purchase order',
    stock_plus_open_po: 'available stock combined with an open PO',
    fast_track: 'a fast-track replenishment order',
    air_freight: 'air freight expediting',
    new_standard_po: 'a new standard purchase order',
  }
  const stratLabel = strategyLabel[option.sourcing_strategy] ?? 'the standard replenishment route'

  const parts: string[] = []
  parts.push(`For this ${tierLabel} customer, sourcing via ${stratLabel} offers the best balance of cost control and service level.`)

  if (option.threshold_compliant) {
    parts.push(`The projected margin of ${marginPct}% is within the approved cost threshold.`)
  } else {
    parts.push(`Note: procurement cost of €${cost.toFixed(2)} exceeds the standard threshold — manager override is required.`)
  }

  if (incremental > 0) {
    parts.push(`An incremental cost of €${incremental.toFixed(2)} is incurred versus the baseline.`)
  }

  if (deliveryPerf < 0.85) {
    parts.push(`Historical delivery performance for this customer is below target (${Math.round(deliveryPerf * 100)}%) — on-time delivery is especially important here.`)
  }

  if (expediteUsage > 0.3) {
    parts.push(`This customer has a high rate of past expedite requests (${Math.round(expediteUsage * 100)}%) — avoid fast-track options unless necessary.`)
  }

  const reliabilityScores = reliability ? Object.values(reliability) : []
  if (reliabilityScores.length > 0) {
    const avg = reliabilityScores.reduce((a, b) => a + b, 0) / reliabilityScores.length
    if (avg >= 0.9) parts.push(`Supplier reliability is strong (avg ${Math.round(avg * 100)}%), supporting confidence in this option.`)
    else if (avg < 0.75) parts.push(`Supplier reliability is below average (avg ${Math.round(avg * 100)}%) — monitor delivery closely.`)
  }

  const risks: string[] = []
  if (!option.threshold_compliant) risks.push('cost deviation requires explicit manager approval')
  if (option.sourcing_strategy === 'air_freight') risks.push('air freight surcharges may compress margin if order volume increases')
  if (option.sourcing_strategy === 'fast_track') risks.push('fast-track lead times depend on supplier capacity at time of order')
  if (expediteUsage > 0.3) risks.push('repeated expediting may signal a structural supply planning gap')
  if (risks.length === 0) risks.push('standard replenishment risk — monitor supplier on-time delivery performance')
  const mainRisk = risks.map((r, i) => i === 0 ? r.charAt(0).toUpperCase() + r.slice(1) : r).join('; ') + '.'

  let confidence = 0.78
  if (option.threshold_compliant) confidence += 0.08
  if (options.length === 1) confidence += 0.05
  if (option.sourcing_strategy === 'air_freight') confidence -= 0.10
  if (option.sourcing_strategy === 'fast_track') confidence -= 0.05
  confidence = Math.min(0.96, Math.max(0.55, Math.round(confidence * 100) / 100))

  return {
    recommended_option_id: option.id,
    recommendation: strategyCode(option.sourcing_strategy),
    reasoning: parts.join(' '),
    main_risk: mainRisk,
    confidence,
  }
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 })
  const payload = await request.json().catch(() => null)
  const options = Array.isArray(payload?.options) ? payload.options as Option[] : []
  if (options.length === 0) return Response.json({ error: 'No options supplied.' }, { status: 400 })
  return Response.json(recommend(options, payload))
})
