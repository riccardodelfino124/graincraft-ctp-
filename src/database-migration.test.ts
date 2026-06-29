import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const migration = readFileSync(join(process.cwd(), 'supabase/migrations/20260628233000_operational_ctp.sql'), 'utf8')
const correctiveMigration = readFileSync(join(process.cwd(), 'supabase/migrations/20260629100000_corrective_ctp_reliability.sql'), 'utf8')
const finalOptionMigration = readFileSync(join(process.cwd(), 'supabase/migrations/20260629123000_prune_stock_covered_options.sql'), 'utf8')
const baseline = readFileSync(join(process.cwd(), 'supabase/migrations/20260628220000_initial_remote_schema.sql'), 'utf8')
const thresholdFixMigration = readFileSync(join(process.cwd(), 'supabase/migrations/20260629150000_fix_std_primary_threshold_compliant.sql'), 'utf8')

describe('database migration coverage', () => {
  it('keeps source material codes as text fields', () => {
    expect(baseline).toContain('"material" character varying(20)')
    expect(baseline).not.toMatch(/"material"\s+integer/i)
  })

  it('creates operational CTP tables and RPCs', () => {
    expect(migration).toContain('create table if not exists public.quote_requests')
    expect(migration).toContain('create table if not exists public.commitment_allocations')
    expect(migration).toContain('create or replace function public.calculate_ctp_options')
    expect(migration).toContain('create or replace function public.confirm_quote_option')
    expect(migration).toContain('create or replace function public.adjust_inventory')
  })

  it('uses operational date and working-day functions', () => {
    expect(migration).toContain('create or replace function public.get_operational_date')
    expect(migration).toContain('create or replace function public.add_working_days')
    expect(migration).toContain('create or replace function public.working_days_between')
  })

  it('adds concurrency-safe confirmation and shortage sourcing corrections', () => {
    expect(correctiveMigration).toContain('pg_advisory_xact_lock')
    expect(correctiveMigration).toContain('STALE_QUOTE')
    expect(correctiveMigration).toContain('Air freight uses the standard vendor price plus contractual freight cost')
    expect(correctiveMigration).toContain('created_by_system')
    expect(correctiveMigration).toContain('persist_quote_recommendation')
  })

  it('prunes irrelevant alternatives for stock-covered quotes', () => {
    expect(finalOptionMigration).toContain('if v_stock_qty >= p_requested_quantity then')
    expect(finalOptionMigration).toContain('stock_plus_open_po')
    expect(finalOptionMigration).toContain("case when v_stock_qty > 0 then 'Stock plus open PO' else 'Existing open PO' end")
    expect(finalOptionMigration).not.toMatch(/drop table|truncate/i)
  })

  it('respects cost threshold for standard primary replenishment option', () => {
    expect(thresholdFixMigration).toContain("'STD_PRIMARY'")
    expect(thresholdFixMigration).not.toContain('v_shortage > 0, true, v_plan')
    expect(thresholdFixMigration).toContain("coalesce(((v_cost->>'procurement_cost')::numeric - v_baseline_cost) / nullif(v_baseline_cost, 0) * 100, 0) <= v_max_cost")
    expect(thresholdFixMigration).not.toMatch(/drop table|truncate/i)
  })
})
