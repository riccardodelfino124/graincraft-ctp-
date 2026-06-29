# Test Scenarios

- Source tables exist and preserve material codes with leading zeroes.
- Sufficient stock returns a current-stock option.
- Existing active allocations reduce free stock.
- Open POs produce a buffered availability date.
- Standard replenishment produces a new standard PO option.
- Secondary vendors and fast-track contracts produce alternate options when present.
- Each option has one customer-facing promise date.
- Threshold settings affect automatic versus review status.
- Confirmation creates one commitment and allocation rows.
- Repeated confirmation returns the existing active commitment.
- Inventory adjustment updates stock only through RPC and logs the delta.
- AI failure returns deterministic fallback.
- Demo mode uses the configured operational reference date.
- Stale quote confirmation raises `STALE_QUOTE`.
- New supply creates a real system PO in `open_pos`.
- 51817 air freight uses standard unit price plus freight cost per expedited unit.
- Historical null-delivery rows import as active legacy commitments.
