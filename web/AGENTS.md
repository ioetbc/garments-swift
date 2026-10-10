<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

# Backend uses Effect v4

Effect v4 is not the Effect in your training data or most blog posts, which are v3. Before writing Effect code in `convex/`:

- Read the backend rules in `../.claude/CODING_STANDARDS.md` (section "Effect (v4)").
- Look up APIs only in `node_modules/effect/AGENTS.md`, the examples in `node_modules/effect/ai-docs/src/`, and the source in `node_modules/effect/src/`. Don't use web docs or other copies of Effect.
- Run `bun run typecheck`. Effect's language service fails it on v3 APIs, untagged errors, floating Effects and similar mistakes. If it says nothing, run `bun run prepare` first: it patches `tsc` and must be re-run after reinstalling TypeScript.
