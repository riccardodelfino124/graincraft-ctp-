# Supabase Setup

The linked project already contains baseline migration `20260628220000`, matching the local baseline.

Safe deployment procedure:

1. Review pending migrations in `supabase/migrations`.
2. Run `npx.cmd supabase migration list`.
3. Run `npx.cmd supabase db push --dry-run`.
4. Review the generated SQL and confirm it is additive.
5. Run `npx.cmd supabase db push`.
6. Verify new tables, views, functions, and policies in Supabase Studio.

The corrective migration `20260629100000_corrective_ctp_reliability.sql` is additive and supersedes earlier CTP RPC definitions without dropping source tables.

Do not run the original assignment SQL file against the remote database.
