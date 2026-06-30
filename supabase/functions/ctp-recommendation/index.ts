type Option = {
  id: string
  option_code?: string
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

function buildReasoning(option: Option, payload: Record<string, unknown>): string {
  const tier = String(payload.customer_tier ?? 'standard').toLowerCase()
  const margin = Number(option.projected_margin)
  const cost = Number(option.procurement_cost)
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
    parts.push(`Historical delivery performance for this customer is below target (${Math.round(deliveryPerf * 100)}%) — on-time delivery is especially important.`)
  }

  if (expediteUsage > 0.3) {
    parts.push(`This customer has a high rate of past expedite requests (${Math.round(expediteUsage * 100)}%) — avoid fast-track unless necessary.`)
  }

  const reliabilityScores = reliability ? Object.values(reliability) : []
  if (reliabilityScores.length > 0) {
    const avgReliability = reliabilityScores.reduce((a, b) => a + b, 0) / reliabilityScores.length
    if (avgReliability >= 0.9) parts.push(`Supplier reliability is strong (avg ${Math.round(avgReliability * 100)}%), supporting confidence in this option.`)
    else if (avgReliability < 0.75) parts.push(`Supplier reliability is below average (avg ${Math.round(avgReliability * 100)}%) — monitor closely.`)
  }

  return parts.join(' ')
}

function buildRisk(option: Option, payload: Record<string, unknown>): string {
  const risks: string[] = []
  if (!option.threshold_compliant) risks.push('cost deviation requires manager approval')
  if (option.sourcing_strategy === 'air_freight') risks.push('air freight surcharges may impact margin if volume increases')
  if (option.sourcing_strategy === 'fast_track') risks.push('fast-track lead times depend on supplier capacity availability')
  if (Number(payload.historical_expedite_usage ?? 0) > 0.3) risks.push('repeated expediting may signal a structural supply planning issue')
  if (risks.length === 0) risks.push('standard replenishment risk — monitor supplier on-time delivery')
  return risks.map((r, i) => (i === 0 ? r.charAt(0).toUpperCase() + r.slice(1) : r)).join('; ') + '.'
}

function buildConfidence(option: Option, options: Option[]): number {
  let score = 0.78
  if (option.threshold_compliant) score += 0.08
  if (options.length === 1) score += 0.05
  if (option.sourcing_strategy === 'air_freight') score -= 0.1
  if (option.sourcing_strategy === 'fast_track') score -= 0.05
  return Math.min(0.96, Math.max(0.55, Math.round(score * 100) / 100))
}

function fallback(options: Option[], payload: Record<string, unknown> = {}): Recommendation {
  const sorted = [...options].sort((a, b) => {
    if (a.threshold_compliant !== b.threshold_compliant) return a.threshold_compliant ? -1 : 1
    if (a.promised_delivery_date !== b.promised_delivery_date) return a.promised_delivery_date.localeCompare(b.promised_delivery_date)
    return Number(a.procurement_cost) - Number(b.procurement_cost)
  })
  const option = sorted[0]
  if (!option) return { recommended_option_id: '', recommendation: 'USE_STANDARD', reasoning: 'No options available.', main_risk: 'No options to evaluate.', confidence: 0 }
  return {
    recommended_option_id: option.id,
    recommendation: strategyCode(option.sourcing_strategy),
    reasoning: buildReasoning(option, payload),
    main_risk: buildRisk(option, payload),
    confidence: buildConfidence(option, options),
  }
}

function validate(value: unknown, options: Option[]): Recommendation | null {
  if (!value || typeof value !== 'object') return null
  const candidate = value as Partial<Recommendation>
  const validRecommendation = ['USE_STANDARD', 'USE_EXISTING_PO', 'USE_FAST_TRACK', 'USE_AIR_FREIGHT'].includes(String(candidate.recommendation))
  const validOption = options.some((option) => option.id === candidate.recommended_option_id)
  const confidence = Number(candidate.confidence)
  if (!validRecommendation || !validOption || !Number.isFinite(confidence) || confidence < 0 || confidence > 1) return null
  if (typeof candidate.reasoning !== 'string' || typeof candidate.main_risk !== 'string') return null
  return {
    recommended_option_id: candidate.recommended_option_id!,
    recommendation: candidate.recommendation!,
    reasoning: candidate.reasoning,
    main_risk: candidate.main_risk,
    confidence,
  }
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 })

  const payload = await request.json().catch(() => null)
  const options = Array.isArray(payload?.options) ? payload.options as Option[] : []
  if (options.length === 0) {
    return Response.json({ error: 'No deterministic options supplied.' }, { status: 400 })
  }

  const apiKey = Deno.env.get('GEMINI_API_KEY')
  const model = Deno.env.get('GEMINI_MODEL') ?? 'gemini-2.0-flash'
  if (!apiKey) return Response.json(fallback(options, payload))

  const systemPrompt = 'You are a supply chain decision assistant for GrainCraft Foods. Recommend exactly one CTP sourcing option. Base your reasoning on customer tier, historical performance, costs, and delivery dates. Never invent option IDs, dates, or costs — use only the data provided. Return strict JSON only, no markdown.'

  const userPrompt = JSON.stringify({
    quote_request: payload.quote_request,
    customer_tier: payload.customer_tier,
    historical_customer_order_value: payload.historical_customer_order_value,
    historical_delivery_performance: payload.historical_delivery_performance,
    historical_expedite_usage: payload.historical_expedite_usage,
    current_stock: payload.current_stock,
    active_commitments: payload.active_commitments,
    open_pos: payload.open_pos,
    supplier_reliability: payload.supplier_reliability,
    options,
    thresholds: payload.thresholds,
    escalation_reason: payload.escalation_reason,
    output_schema: {
      recommended_option_id: 'valid option UUID from the options list above',
      recommendation: 'USE_STANDARD | USE_EXISTING_PO | USE_FAST_TRACK | USE_AIR_FREIGHT',
      reasoning: 'short business explanation referencing customer tier and cost impact',
      main_risk: 'short risk explanation',
      confidence: 'number between 0 and 1',
    },
  })

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 10_000)
  try {
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`
    const response = await fetch(url, {
      method: 'POST',
      signal: controller.signal,
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: systemPrompt }] },
        contents: [{ role: 'user', parts: [{ text: userPrompt }] }],
        generationConfig: { responseMimeType: 'application/json' },
      }),
    })
    clearTimeout(timeout)
    if (!response.ok) return Response.json(fallback(options, payload))
    const data = await response.json()
    const text: string = data?.candidates?.[0]?.content?.parts?.[0]?.text ?? ''
    if (!text) return Response.json(fallback(options, payload))
    const parsed = JSON.parse(text)
    return Response.json(validate(parsed, options) ?? fallback(options, payload))
  } catch {
    clearTimeout(timeout)
    return Response.json(fallback(options, payload))
  }
})
