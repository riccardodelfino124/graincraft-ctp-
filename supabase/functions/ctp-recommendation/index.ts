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

function fallback(options: Option[], reason = 'AI recommendation unavailable. Deterministic recommendation shown.'): Recommendation {
  const sorted = [...options].sort((a, b) => {
    if (a.threshold_compliant !== b.threshold_compliant) return a.threshold_compliant ? -1 : 1
    if (a.promised_delivery_date !== b.promised_delivery_date) return a.promised_delivery_date.localeCompare(b.promised_delivery_date)
    return Number(a.procurement_cost) - Number(b.procurement_cost)
  })
  const option = sorted[0]
  return {
    recommended_option_id: option?.id ?? '',
    recommendation: option?.sourcing_strategy === 'existing_open_po' || option?.sourcing_strategy === 'stock_plus_open_po' ? 'USE_EXISTING_PO' : option?.sourcing_strategy === 'fast_track' ? 'USE_FAST_TRACK' : option?.sourcing_strategy === 'air_freight' ? 'USE_AIR_FREIGHT' : 'USE_STANDARD',
    reasoning: reason,
    main_risk: 'Review deterministic availability, cost, and supplier reliability before override.',
    confidence: option ? 0.72 : 0,
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
  if (!apiKey) return Response.json(fallback(options))

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
    if (!response.ok) return Response.json(fallback(options))
    const data = await response.json()
    const text: string = data?.candidates?.[0]?.content?.parts?.[0]?.text ?? ''
    if (!text) return Response.json(fallback(options, 'AI returned empty response. Deterministic recommendation shown.'))
    const parsed = JSON.parse(text)
    return Response.json(validate(parsed, options) ?? fallback(options, 'AI returned invalid output. Deterministic recommendation shown.'))
  } catch {
    clearTimeout(timeout)
    return Response.json(fallback(options))
  }
})
