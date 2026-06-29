import { describe, expect, it } from 'vitest'
import { airFreightUnitCost, allocationTotal, buildShortagePlan, classifyStrategy, deliveryDelayWorkingDays, procurementCost, shouldGenerateSourcingAlternatives, validateStockCapacity } from './ctp-logic'

describe('CTP corrective behaviour', () => {
  it('sources only the uncovered shortage from a new PO', () => {
    const plan = buildShortagePlan(300, 80, 3.57)
    expect(plan).toEqual([
      { source_type: 'stock', quantity: 80, unit_cost: 3.57 },
      { source_type: 'new_po', quantity: 220, unit_cost: 3.57 },
    ])
    expect(allocationTotal(plan)).toBe(300)
  })

  it('does not generate sourcing alternatives when stock fully covers the request', () => {
    expect(shouldGenerateSourcingAlternatives(140, 138)).toBe(false)
    const plan = buildShortagePlan(138, 140, 3.57)
    expect(plan).toHaveLength(1)
    expect(classifyStrategy(plan)).toBe('current_stock')
    expect(allocationTotal(plan)).toBe(138)
  })

  it('classifies options from positive allocation quantities only', () => {
    expect(classifyStrategy([{ source_type: 'stock', quantity: 80, unit_cost: 3.57 }, { source_type: 'open_po', quantity: 20, unit_cost: 3.57 }])).toBe('stock_plus_open_po')
    expect(classifyStrategy([{ source_type: 'stock', quantity: 138, unit_cost: 3.57 }, { source_type: 'new_po', quantity: 0, unit_cost: 4.23, sourcing_mode: 'fast_track' }])).toBe('current_stock')
    expect(classifyStrategy([{ source_type: 'new_po', quantity: 10, unit_cost: 4.23, sourcing_mode: 'fast_track' }])).toBe('fast_track')
    expect(classifyStrategy([{ source_type: 'new_po', quantity: 10, unit_cost: 24.91, sourcing_mode: 'air_freight' }])).toBe('air_freight')
  })

  it('includes open PO capacity before creating residual new supply', () => {
    const plan = buildShortagePlan(300, 80, 4, [{ source_type: 'open_po', quantity: 100, unit_cost: 3.75 }])
    expect(plan.map((allocation) => allocation.quantity)).toEqual([80, 100, 120])
    expect(procurementCost(plan)).toBe(80 * 4 + 100 * 3.75 + 120 * 4)
  })

  it('uses standard price plus freight for 51817 air freight', () => {
    expect(airFreightUnitCost(24.11, 0.8)).toBe(24.91)
    expect(airFreightUnitCost(12.4, 0.8)).toBe(13.2)
  })

  it('does not count earlier delivery as a positive delay', () => {
    expect(deliveryDelayWorkingDays(new Date('2026-06-19'), new Date('2026-06-16'))).toBe(0)
    expect(deliveryDelayWorkingDays(new Date('2026-06-19'), new Date('2026-06-19'))).toBe(0)
  })

  it('counts later working-day deviation across a weekend', () => {
    expect(deliveryDelayWorkingDays(new Date('2026-06-19'), new Date('2026-06-23'))).toBe(2)
  })

  it('throws STALE_QUOTE when stock capacity changed after calculation', () => {
    const plan = buildShortagePlan(80, 80, 3.57)
    expect(() => validateStockCapacity(plan, 20)).toThrow('STALE_QUOTE')
  })
})
