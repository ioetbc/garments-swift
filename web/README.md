# Garms backend

The Convex backend for the Garms iOS app: schema, per-User functions and their tests.
Setup, environment variables and deployment are in the [repository README](../README.md#convex-backend).

```sh
bun install
bun run dev        # convex dev: local or dev deployment; regenerates convex/_generated
bun run test       # convex-test, in memory
bun run typecheck  # includes Effect's language service checks
```
