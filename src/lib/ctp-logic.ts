export type Allocation = {
  source_type: 'stock' | 'open_po' | 'new_po'
  quantity: number
  unit_cost: number
  overdue?: boolean
}

export function deliveryDelayWorkingDays(standard: Date, proposed: Date) {
  if (proposed <= standard) return 0
  let days = 0
  const cursor = new Date(standard)
  while (cursor < proposed) {
    cursor.setDate(cursor.getDate() + 1)
    const day = cursor.getDay()
    if (day !== 0 && day !== 6) days += 1
  }
  return days
}

export function buildShortagePlan(requested: number, stock: number, newPoUnitCost: number, existing: Allocation[] = []) {
  const plan: Allocation[] = []
  const stockQty = Math.min(requested, Math.max(stock, 0))
  if (stockQty > 0) plan.push({ source_type: 'stock', quantity: stockQty, unit_cost: newPoUnitCost })
  let shortage = requested - stockQty
  for (const allocation of existing) {
    if (shortage <= 0) break
    const qty = Math.min(shortage, allocation.quantity)
    plan.push({ ...allocation, quantity: qty })
    shortage -= qty
  }
  if (shortage > 0) plan.push({ source_type: 'new_po', quantity: shortage, unit_cost: newPoUnitCost })
  return plan
}

export function allocationTotal(plan: Allocation[]) {
  return plan.reduce((sum, allocation) => sum + allocation.quantity, 0)
}

export function procurementCost(plan: Allocation[]) {
  return plan.reduce((sum, allocation) => sum + allocation.quantity * allocation.unit_cost, 0)
}

export function airFreightUnitCost(standardUnitPrice: number, freightCostPerUnit: number) {
  return Math.round((standardUnitPrice + freightCostPerUnit) * 10000) / 10000
}

export function validateStockCapacity(plan: Allocation[], availableStock: number) {
  const stockQuantity = plan.filter((allocation) => allocation.source_type === 'stock').reduce((sum, allocation) => sum + allocation.quantity, 0)
  if (stockQuantity > availableStock) throw new Error('STALE_QUOTE')
  return true
}

export function shouldGenerateSourcingAlternatives(freeStock: number, requestedQuantity: number) {
  return freeStock < requestedQuantity
}

export function classifyStrategy(plan: Array<Allocation & { sourcing_mode?: string }>) {
  const positive = plan.filter((allocation) => allocation.quantity > 0)
  const hasStock = positive.some((allocation) => allocation.source_type === 'stock')
  const hasOpenPo = positive.some((allocation) => allocation.source_type === 'open_po')
  const hasNewPo = positive.some((allocation) => allocation.source_type === 'new_po')
  const hasFastTrack = positive.some((allocation) => allocation.sourcing_mode === 'fast_track')
  const hasAirFreight = positive.some((allocation) => allocation.sourcing_mode === 'air_freight')

  if (hasAirFreight) return 'air_freight'
  if (hasFastTrack) return 'fast_track'
  if (hasNewPo) return 'new_standard_po'
  if (hasStock && hasOpenPo) return 'stock_plus_open_po'
  if (hasOpenPo) return 'existing_open_po'
  return 'current_stock'
}
