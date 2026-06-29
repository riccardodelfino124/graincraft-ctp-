# Smoke Test Results

Date: 2026-06-29

## Automated Validation

- `npm run typecheck`: passed.
- `npm run lint`: passed.
- `npm run test`: passed, 3 files and 12 tests.
- `npm run build`: passed. Vite reported a non-blocking chunk-size warning.
- `npx.cmd supabase db push --dry-run`: passed and showed only `20260629100000_corrective_ctp_reliability.sql`.
- `npx.cmd supabase db push`: applied `20260629100000_corrective_ctp_reliability.sql`.
- `npx.cmd supabase migration list`: remote history includes `20260629100000`.
- `npx.cmd supabase functions deploy ctp-recommendation`: deployed.

## Manual Authenticated Smoke Tests

The browser-based smoke flows require a valid Supabase Auth user. No working application credentials were available in this session, so the following manual flows are pending:

- Flow A: sufficient stock quote through automatic commitment.
- Flow B: human review with override reason.
- Flow C: competing demand stale quote.
- Flow D: 51817 air freight option.
- Flow E: settings threshold change.
- Flow F: delivered commitment and delivery accuracy.

## Verified By Code And Migration

- Auto-confirmation now calls the atomic confirmation RPC before setting `auto_confirmed`.
- Confirmation uses a material-level advisory transaction lock and raises `STALE_QUOTE` when allocations are no longer feasible.
- Shortage sourcing allocates stock/open PO first and creates new supply only for the residual shortage.
- 51817 air freight uses `unit_price_standard + expedite_freight_cost`.
- New supply confirmation creates system `open_pos` records.
- Historical null-delivery rows are imported as traceable active legacy commitments.
