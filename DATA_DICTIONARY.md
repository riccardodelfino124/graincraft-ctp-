# Data Dictionary

| Business concept | Source/application field |
| --- | --- |
| SKU / material code | `items.material`, `contracts.material`, `open_pos.material`, `orders_history.material` |
| Product description | `items.description` |
| Physical stock | `items.current_stock` |
| Average daily demand | `items.avg_daily_demand` |
| Vendor | `vendors.vendor_code`, `vendors.vendor_name` |
| Contract standard cost | `contracts.unit_price_standard` |
| Contract expedite cost | `contracts.unit_price_expedite` |
| Standard lead time | `contracts.lead_time_standard_wd` |
| Expedite lead time | `contracts.lead_time_expedite_wd` |
| Open purchase order quantity | `open_pos.quantity_ordered` |
| Received purchase order quantity | `open_pos.quantity_received` |
| Expected PO date | `open_pos.expected_delivery_date` |
| Customer | `customers.customer_id`, derived from `orders_history.customer_id` |
| Customer tier | `customers.customer_tier`, derived from `orders_history.customer_tier` |
| Quote request | `quote_requests` |
| Deterministic sourcing option | `quote_options` |
| Customer promise | `commitments` |
| Reserved supply | `commitment_allocations` |
| System-created purchase order | `open_pos` with `created_by_system = true`, `sourcing_mode`, `unit_cost`, and originating quote/commitment fields |
| AI or fallback recommendation | recommendation fields on `quote_requests`, finalized in `decision_logs` |
| Decision audit | `decision_logs` |

Material codes are strings and must retain leading zeroes.
