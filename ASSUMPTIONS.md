# Assumptions

- Public holidays are not modelled; working days exclude Saturday and Sunday only.
- Open PO dates are historical relative to the real date, so demo mode defaults to `2026-06-12`.
- The assignment SQL contains 22 historical orders with no actual delivery date, total quantity 3,690. They are treated as plausible open customer demand and imported idempotently as active `legacy_import` commitments.
- Unknown legacy allocations are not invented; legacy demand reduces free stock conservatively and remains traceable through `source_order_id`.
- Customer names are not present in the assignment data; the UI displays customer IDs.
- Suggested selling price can be derived later from historical order price; the current quote form accepts an explicit user-entered price.
- Customer-facing partial fulfilment is out of scope; every option exposes one promise date for the full requested quantity.
- Overdue POs are surfaced in ATP and PO views. Options depending on overdue unverified POs require review and are not silently auto-confirmed.
- There is no live ERP synchronization in this implementation.
