# Corrective Implementation Plan

## Confirmed Defects

- `calculate_ctp_options` sets `quote_requests.status = auto_confirmed` before a commitment, allocations, and decision log exist.
- `confirm_quote_option` does not acquire a SKU-level lock, does not revalidate every allocation against current capacity, and can accept stale allocation plans.
- New standard, secondary, and fast-track options source the full requested quantity instead of the residual shortage after usable stock and open POs.
- Vendor `51817` air-freight contracts use `expedite_freight_cost` with no `unit_price_expedite`; the current engine does not generate these options.
- Confirmed `new_po` allocations are not represented by real `open_pos` records.
- The Edge Function exists but is not invoked from the review workflow or persisted before human decisions.
- Review, settings, and commitment management pages are operationally incomplete.
- Historical orders with `actual_delivery_date is null` exist in the assignment SQL and need explicit treatment.
- Delivery deviation must treat earlier-than-standard delivery as zero delay.
- Dashboard metrics count request statuses rather than confirmed commitments in some places.

## Affected Files

- `supabase/migrations/20260628233000_operational_ctp.sql`
- new corrective migration under `supabase/migrations/`
- `src/App.tsx`
- `src/App.css`
- `src/database-migration.test.ts`
- documentation files in the repository root
- `supabase/functions/ctp-recommendation/index.ts`

## Proposed Database Changes

- Add operational columns to `open_pos` so system-created POs can be represented without duplicating the purchase-order concept.
- Add recommendation persistence columns to `quote_requests`.
- Add cancellation audit fields to `commitments`.
- Replace `calculate_ctp_options` with shortage-based option generation and real auto-confirm orchestration through `confirm_quote_option`.
- Replace `confirm_quote_option` with advisory-lock, row-lock, stale-quote-aware validation.
- Create new POs during confirmation for `new_po` allocations and attach allocations to the generated PO IDs.
- Add settings update and commitment action RPCs.
- Import null-actual-delivery history rows as traceable `legacy_import` commitments without invented allocation sources.

## Proposed Frontend Changes

- Show STALE_QUOTE as a clear recalculate message.
- Replace review table with quote detail, recommendation, option selection, and override reason.
- Invoke `ctp-recommendation` for pending-review quotes when enabled and persist the returned recommendation.
- Make settings editable for admins using validated controls.
- Add commitment delivery and cancellation actions through RPCs.
- Make dashboard and email preview read real commitments.

## Test Plan

- Keep fast unit tests for formatting and migration coverage.
- Add pure TypeScript behavioural tests for shortage allocation, delivery deviation, stale capacity validation, air-freight costing, and deterministic fallback ranking.
- Run lint, test, typecheck, build.
- Use Supabase dry-run before remote migration push.

## Migration Plan

1. Keep applied migrations unchanged.
2. Add one corrective additive migration.
3. Run `npx.cmd supabase migration list`.
4. Run `npx.cmd supabase db push --dry-run`.
5. Confirm no source table is dropped, truncated, or recreated.
6. Apply with `npx.cmd supabase db push`.

## Deployment Sequence

1. Apply database migration.
2. Deploy updated Edge Function.
3. Build frontend.
4. Smoke-test quote calculation, auto-confirm, review override, settings, commitment delivery, and air-freight options.

## Rollback Considerations

- No source data is dropped or truncated.
- New columns are nullable or have conservative defaults.
- Replaced functions can be superseded by another additive migration if rollback is needed.
- System-created POs are traceable through `created_by_system` and originating quote/commitment fields.

## Final Quote Result And Option Corrections

- Confirmed defect: stock-covered quotes can still receive materially duplicate options such as standard replenishment or fast-track with allocation plans containing only stock.
- Confirmed defect: Quote Result keeps radio buttons and confirmation buttons visible after a quote has already created a commitment.
- Confirmed defect: option badges use recommendation/array position instead of the committed `commitments.quote_option_id`.
- Confirmed defect: money formatting uses USD, while the assignment data is in EUR.
- Database correction: add a new additive migration replacing `calculate_ctp_options` so stock-covered quotes return only the `current_stock` option and stock+PO options are labelled from actual positive allocations.
- Frontend correction: fetch the commitment and allocations for the quote, render a confirmed banner and read-only alternatives for final quotes, and display allocation rows in a human-readable table.
- Test correction: add fixture-level tests for stock-covered option pruning, duplicate prevention, confirmed read-only UI logic, allocation totals, and EUR formatting.
