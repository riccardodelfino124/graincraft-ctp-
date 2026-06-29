# Agent Notes

- Work only in `C:\Users\utente\graincraft-ctp`.
- Do not expose `.env.local` values.
- Do not run `data/database_CTP_assignment.sql` against the linked database.
- Never run destructive remote commands such as `supabase db reset --linked`, `DROP TABLE`, or `TRUNCATE`.
- Use additive migrations in `supabase/migrations`.
- Run `npx.cmd supabase db push --dry-run` before any real remote push.
- Treat PostgreSQL RPCs as the source of truth for CTP dates, costs, margins, allocations, and inventory changes.
