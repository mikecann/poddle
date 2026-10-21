# Poddle

Mike's own podcast player for iPhone, iPad and Mac, built to replace Overcast. SwiftUI app plus a Convex backend.

- `docs/decisions.md`: what's been decided
- `docs/product-spec.md`: how it should behave
- `docs/architecture.md`: how the code is laid out
- `designs/c-earful-warm.html`: the chosen look (open it in a browser)
- `docs/api.md`: the backend API the app is written against, including the offline/outbox contract

## Backend

The Convex backend lives in `convex/`. Node 24+.

```sh
npm install
npm run dev:local    # local anonymous Convex deployment, no account needed
npx convex env set PODDLE_API_TOKEN <long random string>
```

| Script | What it does |
|---|---|
| `npm run dev` | `convex dev` against the linked deployment (watch, push, codegen) |
| `npm run dev:local` | `convex dev` against a local anonymous deployment |
| `npm run codegen` | Regenerate `convex/_generated` |
| `npm run deploy` | `convex deploy` to production |
| `npm run typecheck` | `tsc` over `convex/` and the tests |
| `npm test` | Vitest + convex-test, once |
| `npm run test:watch` | Vitest in watch mode |
| `npm run check` | Typecheck, then tests |
