# Backend uses Effect v4

Effect v4 is not the Effect in your training data or most blog posts, which are v3. Before writing Effect code in `convex/`:

- Read the backend rules in `../.claude/CODING_STANDARDS.md` (section "Effect (v4)").
- Look up APIs only in `node_modules/effect/AGENTS.md`, the examples in `node_modules/effect/ai-docs/src/`, and the source in `node_modules/effect/src/`. Don't use web docs or other copies of Effect.
- Run `bun run typecheck`. Effect's language service fails it on v3 APIs, untagged errors, floating Effects and similar mistakes. If it says nothing, run `bun run prepare` first: it patches `tsc` and must be re-run after reinstalling TypeScript.
