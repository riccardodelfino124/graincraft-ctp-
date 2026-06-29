# GrainCraft CTP

Capable-to-Promise application for GrainCraft Foods. It answers when a complete requested quantity can realistically be delivered, which sourcing strategy should be used, and what procurement cost and projected margin result.

## Stack

- React, TypeScript, Vite
- React Router, TanStack Query, React Hook Form, Zod
- Supabase Auth, PostgreSQL, RLS, RPC functions, Edge Functions
- Vitest and React Testing Library

## Setup

```bash
npm install
cp .env.example .env.local
```

Fill `.env.local` with:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`

Do not commit `.env.local`.

## Development

```bash
npm run dev
```

## Build

```bash
npm run build
```

## Tests

```bash
npm run test
```

## Supabase

Inspect migration state:

```bash
npx.cmd supabase migration list
```

Preview database changes:

```bash
npx.cmd supabase db push --dry-run
```

Apply approved additive migrations:

```bash
npx.cmd supabase db push
```

Deploy the AI recommendation Edge Function:

```bash
npx.cmd supabase functions deploy ctp-recommendation
```

## Demo Flow

1. Create and promote the first admin user as described in `AUTH_SETUP.md`.
2. Sign in.
3. Open New Quote.
4. Select a customer, material, quantity, and selling price.
5. Calculate delivery promise.
6. Review deterministic options and confirm the recommended option.
7. Inspect Dashboard, Inventory, Purchase Orders, Commitments, and Decision History.

## Documentation

- `ARCHITECTURE.md`
- `DATA_DICTIONARY.md`
- `ASSUMPTIONS.md`
- `SUPABASE_SETUP.md`
- `AUTH_SETUP.md`
- `TEST_SCENARIOS.md`
- `DEPLOYMENT.md`
- `CTP_DECISION_LOGIC.md`
