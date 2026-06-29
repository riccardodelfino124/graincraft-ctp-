# CTP Decision Logic

## ATP Calculation

Free stock is current item stock minus active stock allocations and active legacy demand imported from historical orders with missing actual delivery date. Open PO availability is ordered quantity minus received quantity and active allocations.

## Supply And Demand Events

Supply events are current stock, unallocated open POs, and system-created POs generated during confirmation. Demand events are active commitments, including legacy imports. Legacy imports are traceable commitments without invented allocation rows.

## Shortage Calculation

For every option the engine first uses available stock, then applicable open PO capacity for the candidate date, then sources only the residual shortage from a new PO, secondary vendor, fast-track, or air freight.

## Single-Delivery Rule

Every quote option has one customer-facing `promised_delivery_date` for the complete requested quantity. Internal composition is stored in `allocation_plan`.

## Sourcing Options

- Standard: residual shortage through the primary vendor standard contract.
- Secondary: residual shortage through a secondary standard vendor where one exists.
- Fast-track: residual shortage using the secondary vendor expedited price and lead time.
- Air freight: for 51817 contracts, residual shortage uses standard unit price plus `expedite_freight_cost` and the expedite lead time.

## PO Buffer And Overdue POs

Open POs use `open_po_buffer_working_days`. Overdue unreceived POs are visible in the UI and options depending on them are not threshold-compliant for silent auto-confirmation.

## Threshold Logic

Delivery deviation is zero when the proposed date is earlier than or equal to the standard reference date. Later dates count working days only. Cost deviation is based on procurement cost versus baseline replacement cost.

## Auto-Confirm Workflow

`calculate_ctp_options` generates deterministic options, finds the best threshold-compliant option, and invokes `confirm_quote_option`. A quote is `auto_confirmed` only after commitment, allocations, new PO records, and decision log are created in one transaction.

## Human Review Workflow

Pending-review quotes can receive an AI or deterministic fallback recommendation. Managers and admins may accept the recommendation or select another option with a mandatory override reason.

## Concurrency Protection

Confirmation acquires a transaction-level advisory lock by material, locks relevant item and PO rows, recalculates stock and PO capacity, validates the saved allocation plan, and raises `STALE_QUOTE` if capacity changed.

## LLM Boundary

The Edge Function receives deterministic options and may recommend only an existing option ID. It cannot create dates, quantities, costs, margins, or allocation plans. Invalid or unavailable AI responses fall back to deterministic ranking.

## Commitment Cancellation

Cancellation marks the commitment cancelled and preserves audit history. Active allocations stop counting because ATP views only count allocations for active commitments.
