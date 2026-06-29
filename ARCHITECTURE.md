# Architecture

The app is a React, TypeScript, and Vite frontend backed by Supabase PostgreSQL, Auth, RLS, RPC functions, and an Edge Function for optional AI recommendations.

PostgreSQL owns CTP logic. `calculate_ctp_options` creates a quote request and deterministic options using stock, active allocations, legacy demand, open POs, contracts, lead times, costs, margins, thresholds, and `get_operational_date()`. It auto-confirms only by invoking `confirm_quote_option`. `confirm_quote_option` creates one active commitment per quote, materializes allocation rows, and creates real system `open_pos` records for new supply.

Availability is time-phased through `current_item_atp` and `open_po_availability`. Working-day calculations are implemented in `add_working_days` and `working_days_between`.

Concurrency protection uses a material-level advisory transaction lock, row locks, stale allocation validation, and a unique partial index preventing multiple active commitments for one quote. Allocation rows reserve stock, open PO, or newly created PO supply.

RLS exposes read access to authenticated users and restricts settings, profile role changes, inventory adjustment, and commitment status changes through role-aware policies and security-definer RPCs.

The Edge Function boundary never lets the LLM create authoritative dates, quantities, costs, or margins. It may choose only among existing deterministic option IDs and falls back to deterministic ranking.
