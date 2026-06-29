import { describe, expect, it } from 'vitest'
import { money, number, pct } from './format'

describe('format helpers', () => {
  it('formats currency and nullable numbers', () => {
    expect(money(12.5)).toBe('€12.50')
    expect(number(null)).toBe('N/A')
    expect(number(42.42, 1)).toBe('42.4')
  })

  it('formats ratios and percentages consistently', () => {
    expect(pct(0.5)).toBe('50%')
    expect(pct(12.25)).toBe('12.3%')
  })
})
