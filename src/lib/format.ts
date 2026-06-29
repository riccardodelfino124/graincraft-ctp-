export function money(value: number | null | undefined) {
  return new Intl.NumberFormat('en-IE', {
    style: 'currency',
    currency: 'EUR',
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(Number(value ?? 0))
}

export function number(value: number | null | undefined, digits = 0) {
  if (value === null || value === undefined || Number.isNaN(Number(value))) return 'N/A'
  return new Intl.NumberFormat('en-US', { maximumFractionDigits: digits }).format(Number(value))
}

export function pct(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(Number(value))) return 'N/A'
  const normalized = Math.abs(Number(value)) <= 1 ? Number(value) * 100 : Number(value)
  return `${number(normalized, 1)}%`
}
