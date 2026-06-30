import { describe, expect, it } from 'vitest'
import { computeRecommendation, type RecommendOption } from './recommend'

const base: RecommendOption = {
  id: 'opt-1',
  sourcing_strategy: 'new_standard_po',
  promised_delivery_date: '2026-07-10',
  procurement_cost: 3.00,
  incremental_cost: 0,
  projected_margin: 2.00,
  threshold_compliant: true,
}

describe('computeRecommendation', () => {
  it('picks the single option and shows positive margin within threshold', () => {
    const rec = computeRecommendation([base], 'standard')
    expect(rec.recommended_option_id).toBe('opt-1')
    expect(rec.recommendation).toBe('USE_STANDARD')
    expect(rec.reasoning).toContain('within the approved cost threshold')
    expect(rec.reasoning).not.toContain('Warning')
    expect(rec.reasoning).not.toContain('negative margin')
    expect(rec.confidence).toBeGreaterThan(0.85)
  })

  it('mentions negative margin when margin is below zero', () => {
    const opt: RecommendOption = { ...base, procurement_cost: 3.57, projected_margin: -2.57, threshold_compliant: true }
    const rec = computeRecommendation([opt], 'standard')
    expect(rec.reasoning).toContain('negative margin')
    expect(rec.reasoning).toContain('Warning')
    expect(rec.reasoning).not.toContain('within the approved cost threshold')
    expect(rec.confidence).toBeLessThan(0.70)
    expect(rec.main_risk).toContain('Negative margin')
  })

  it('mentions override when not threshold compliant and margin is positive', () => {
    const opt: RecommendOption = { ...base, projected_margin: 0.50, threshold_compliant: false }
    const rec = computeRecommendation([opt], 'standard')
    expect(rec.reasoning).toContain('manager override is required')
    expect(rec.main_risk).toContain('Cost deviation')
    expect(rec.confidence).toBeLessThan(0.78)
  })

  it('prefers threshold-compliant option over non-compliant even if cheaper', () => {
    const compliant: RecommendOption = { ...base, id: 'opt-compliant', procurement_cost: 5.00, projected_margin: 3.00, threshold_compliant: true }
    const nonCompliant: RecommendOption = { ...base, id: 'opt-cheap', procurement_cost: 2.00, projected_margin: 0.50, threshold_compliant: false }
    const rec = computeRecommendation([nonCompliant, compliant], 'standard')
    expect(rec.recommended_option_id).toBe('opt-compliant')
  })

  it('prefers earlier delivery date when compliance is equal', () => {
    const early: RecommendOption = { ...base, id: 'opt-early', promised_delivery_date: '2026-07-05' }
    const late: RecommendOption = { ...base, id: 'opt-late', promised_delivery_date: '2026-07-15' }
    const rec = computeRecommendation([late, early], 'standard')
    expect(rec.recommended_option_id).toBe('opt-early')
  })

  it('prefers lower cost when compliance and date are equal', () => {
    const cheap: RecommendOption = { ...base, id: 'opt-cheap', procurement_cost: 2.00, projected_margin: 3.00 }
    const expensive: RecommendOption = { ...base, id: 'opt-expensive', procurement_cost: 5.00, projected_margin: 1.00 }
    const rec = computeRecommendation([expensive, cheap], 'standard')
    expect(rec.recommended_option_id).toBe('opt-cheap')
  })

  it('applies gold tier label', () => {
    const rec = computeRecommendation([base], 'gold')
    expect(rec.reasoning).toContain('gold-tier')
  })

  it('applies silver tier label', () => {
    const rec = computeRecommendation([base], 'silver')
    expect(rec.reasoning).toContain('silver-tier')
  })

  it('reduces confidence and adds risk for air freight', () => {
    const opt: RecommendOption = { ...base, sourcing_strategy: 'air_freight' }
    const rec = computeRecommendation([opt], 'standard')
    expect(rec.recommendation).toBe('USE_AIR_FREIGHT')
    expect(rec.main_risk).toContain('Air freight')
    expect(rec.confidence).toBeLessThan(0.80)
  })

  it('reduces confidence and adds risk for fast track', () => {
    const opt: RecommendOption = { ...base, sourcing_strategy: 'fast_track' }
    const rec = computeRecommendation([opt], 'standard')
    expect(rec.recommendation).toBe('USE_FAST_TRACK')
    expect(rec.main_risk).toContain('Fast-track')
  })

  it('maps existing_open_po to USE_EXISTING_PO', () => {
    const opt: RecommendOption = { ...base, sourcing_strategy: 'existing_open_po' }
    const rec = computeRecommendation([opt], 'standard')
    expect(rec.recommendation).toBe('USE_EXISTING_PO')
  })

  it('mentions incremental cost when present', () => {
    const opt: RecommendOption = { ...base, incremental_cost: 1.25 }
    const rec = computeRecommendation([opt], 'standard')
    expect(rec.reasoning).toContain('€1.25')
    expect(rec.reasoning).toContain('incremental')
  })

  it('mentions number of alternatives evaluated', () => {
    const opt2: RecommendOption = { ...base, id: 'opt-2', procurement_cost: 10 }
    const rec = computeRecommendation([base, opt2], 'standard')
    expect(rec.reasoning).toContain('1 alternative option')
  })

  it('confidence is always between 0.40 and 0.96', () => {
    const worst: RecommendOption = { ...base, sourcing_strategy: 'air_freight', projected_margin: -100, procurement_cost: 200, threshold_compliant: false }
    const rec = computeRecommendation([worst, { ...worst, id: 'x2' }], 'standard')
    expect(rec.confidence).toBeGreaterThanOrEqual(0.40)
    expect(rec.confidence).toBeLessThanOrEqual(0.96)
  })
})
