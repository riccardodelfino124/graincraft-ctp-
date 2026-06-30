export type RecommendOption = {
  id: string
  sourcing_strategy: string
  promised_delivery_date: string
  procurement_cost: number
  incremental_cost: number
  projected_margin: number
  threshold_compliant: boolean
}

export type Recommendation = {
  recommended_option_id: string
  recommendation: 'USE_STANDARD' | 'USE_EXISTING_PO' | 'USE_FAST_TRACK' | 'USE_AIR_FREIGHT'
  reasoning: string
  main_risk: string
  confidence: number
}

const STRAT_LABEL: Record<string, string> = {
  existing_open_po: 'an existing open purchase order',
  stock_plus_open_po: 'available stock combined with an open PO',
  fast_track: 'a fast-track replenishment order',
  air_freight: 'air freight expediting',
  new_standard_po: 'a new standard purchase order',
}

function stratCode(s: string): Recommendation['recommendation'] {
  if (s === 'existing_open_po' || s === 'stock_plus_open_po') return 'USE_EXISTING_PO'
  if (s === 'fast_track') return 'USE_FAST_TRACK'
  if (s === 'air_freight') return 'USE_AIR_FREIGHT'
  return 'USE_STANDARD'
}

function tierLabel(tier: string): string {
  const t = tier.toLowerCase()
  if (t === 'gold') return 'gold-tier'
  if (t === 'silver') return 'silver-tier'
  return 'standard'
}

/** Margin as % of revenue (selling price). Revenue = cost + margin. */
function marginPct(cost: number, margin: number): number {
  const revenue = cost + margin
  if (revenue <= 0) return 0
  return Math.round((margin / revenue) * 100)
}

export function computeRecommendation(
  opts: RecommendOption[],
  tier: string,
): Recommendation {
  // Sort: threshold-compliant first, then earliest delivery, then lowest cost
  const sorted = [...opts].sort((a, b) => {
    if (a.threshold_compliant !== b.threshold_compliant) return a.threshold_compliant ? -1 : 1
    const da = a.promised_delivery_date ?? ''
    const db = b.promised_delivery_date ?? ''
    if (da !== db) return da.localeCompare(db)
    return Number(a.procurement_cost ?? 0) - Number(b.procurement_cost ?? 0)
  })

  const opt = sorted[0]
  const label = tierLabel(tier)
  const cost = Number(opt.procurement_cost)
  const margin = Number(opt.projected_margin)
  const pct = marginPct(cost, margin)
  const incremental = Number(opt.incremental_cost)
  const strat = STRAT_LABEL[opt.sourcing_strategy] ?? 'the standard sourcing route'

  const parts: string[] = [
    `For this ${label} customer, sourcing via ${strat} is the recommended option based on cost, compliance, and delivery performance.`,
  ]

  if (margin < 0) {
    parts.push(
      `Warning: this option yields a negative margin of ${pct}% — the selling price does not cover the procurement cost. Manual review is strongly recommended before confirming.`,
    )
  } else if (opt.threshold_compliant) {
    parts.push(`The projected margin of ${pct}% is within the approved cost threshold, supporting automatic confirmation.`)
  } else {
    parts.push(
      `Note: the procurement cost of €${cost.toFixed(2)} exceeds the approved threshold. A manager override is required to confirm this option.`,
    )
  }

  if (incremental > 0) {
    parts.push(`An incremental expedite cost of €${incremental.toFixed(2)} is incurred versus the baseline sourcing plan.`)
  }

  if (opts.length > 1) {
    const altCount = opts.length - 1
    parts.push(`${altCount} alternative option${altCount > 1 ? 's were' : ' was'} evaluated and ranked lower on compliance or cost.`)
  }

  const risks: string[] = []
  if (margin < 0) risks.push('Negative margin — confirm only after pricing review or customer negotiation')
  if (!opt.threshold_compliant) risks.push('Cost deviation requires explicit manager approval before commitment')
  if (opt.sourcing_strategy === 'air_freight') risks.push('Air freight surcharges may further compress margin if order volume changes')
  if (opt.sourcing_strategy === 'fast_track') risks.push('Fast-track availability depends on supplier capacity at time of order')
  if (risks.length === 0) risks.push('Standard replenishment risk — monitor supplier on-time delivery performance')

  let confidence = 0.78
  if (opt.threshold_compliant) confidence += 0.08
  else confidence -= 0.08
  if (opts.length === 1) confidence += 0.04
  if (margin < 0) confidence -= 0.20
  if (pct < -50) confidence -= 0.10
  if (opt.sourcing_strategy === 'air_freight') confidence -= 0.11
  if (opt.sourcing_strategy === 'fast_track') confidence -= 0.05
  confidence = Math.min(0.96, Math.max(0.40, Math.round(confidence * 100) / 100))

  return {
    recommended_option_id: opt.id,
    recommendation: stratCode(opt.sourcing_strategy),
    reasoning: parts.join(' '),
    main_risk: risks.map((r, i) => (i === 0 ? r.charAt(0).toUpperCase() + r.slice(1) : r)).join('; ') + '.',
    confidence,
  }
}
