# Implementation Plan

## Phase 1 - Inspection
- Repository: existing React, TypeScript, Vite app in this directory.
- Supabase: initialized and linked. Local and remote migration history both contain baseline `20260628220000`.
- Source tables verified remotely through Supabase API: `vendors` 3 rows, `items` 20 rows, `contracts` 35 rows, `open_pos` 10 rows, `orders_history` 330 rows.
- Original assignment SQL contains destructive `DROP TABLE` statements and RLS disabling statements, so it is reference-only.

## Phase 2 - Application Foundation
- Add Supabase client, React Router, TanStack Query, React Hook Form, Zod, icons, and tests.
- Replace starter Vite UI with authenticated operations pages.

## Phase 3 - Database
- Add additive migration for customers, profiles, settings, quote requests/options, commitments, allocations, decision logs, inventory adjustments, views, RLS, and RPCs.
- Preserve the five source tables and material codes as text.

## Phase 4 - CTP Engine
- Use PostgreSQL functions for operational date, working days, ATP, quote option calculation, confirmation, and inventory adjustment.
- Prevent double commitment with a unique active quote commitment index.

## Phase 5 - AI Boundary
- Add Supabase Edge Function `ctp-recommendation`.
- Accept only structured deterministic option context and validate the model response.
- Fall back deterministically if secrets or model response are unavailable.

## Phase 6 - Verification
- Run lint, tests, production build, and Supabase dry run before any remote migration push.
- Apply remote migrations only after dry-run SQL is reviewed.
