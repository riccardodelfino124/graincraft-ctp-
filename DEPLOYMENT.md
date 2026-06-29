# Deployment

Build the React app:

```bash
npm run build
```

The production output is `dist/` and can be hosted by any static hosting provider configured with:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`

Database deployment:

```bash
npx.cmd supabase db push --dry-run
npx.cmd supabase db push
```

Before pushing, confirm the pending migration list contains only intended additive migrations and no destructive source-table operations.

Edge Function deployment:

```bash
npx.cmd supabase functions deploy ctp-recommendation
```

Required Supabase secrets:

```bash
npx.cmd supabase secrets set OPENAI_API_KEY=...
npx.cmd supabase secrets set OPENAI_MODEL=...
```
