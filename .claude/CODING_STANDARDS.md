## Effect (v4)

We use **Effect v4**. Most Effect code in training data and blog posts is v3 and will not compile, or will compile against removed APIs. Look up APIs in the installed package source (`node_modules/effect/src`) and its `LLMS.md`. Don't trust memory or old docs.

v3 → v4 names you will be tempted to write:

| Don't write (v3)                          | Write (v4)                    |
| ----------------------------------------- | ----------------------------- |
| `Context.Tag`, `Effect.Service`           | `Context.Service`             |
| `Effect.catchAll` / `catchAllCause`       | `Effect.catch` / `catchCause` |
| `Effect.catchSome`                        | `Effect.catchIf`              |
| `Either`, `Effect.either`                 | `Result`, `Effect.result`     |
| `Effect.async`                            | `Effect.callback`             |
| `Effect.zipRight` / `zipLeft`             | `Effect.andThen` / `tap`      |
| `Layer.scoped`                            | `Layer.effect`                |
| `FiberRef`                                | `Context.Reference`           |
| `Runtime<R>`, `Effect.runPromise` per call | one run at the edge (below)  |
| `@effect/platform`, `@effect/rpc` imports | `effect` / `effect/unstable/*`|

---

Convex function handlers are the edge. Effect must not leak out of them: args, return values and thrown errors stay plain Convex (`v.*` validators, `ConvexError`). Inside, the handler should immediately delegate to one Effect and run it once. More than one `runPromise` in a handler is a red flag.

```ts
export const remove = mutation({
  args: { product: v.string() },
  returns: v.null(),
  handler: (ctx, args) =>
    removeProduct(args.product).pipe(
      Effect.provide(Db.layer(ctx)),
      Effect.catchTag("ProductNotFound", () => Effect.die(new ConvexError("Product not found."))),
      Effect.runPromise,
    ),
});
```

---

Functions that return an Effect are written with `Effect.fn("name")(function* (...) {...})`, not as `() => Effect.gen(...)`. `Effect.fn` adds a tracing span and better stack traces. Don't `.pipe` an `Effect.fn`. Pass the combinators as extra arguments instead.

```ts
const removeProduct = Effect.fn("removeProduct")(function* (key: string) {
  const db = yield* Db;
  const product = yield* db.findProduct(key);
  // ...
});
```

---

Dependencies (Convex `ctx.db`, storage, external APIs, clock, config) are **services**: a `Context.Service` class with a static `layer`. Code `yield*`s the service and never takes `ctx` as a parameter. Tests provide a different layer. Never make a layer optional.

```ts
export class Db extends Context.Service<Db, {
  findProduct(key: string): Effect.Effect<Product, ProductNotFound>;
}>()("garms/Db") {
  static layer = (ctx: MutationCtx) => Layer.succeed(Db, Db.of({ /* ... */ }));
}
```

---

Never use `new Error()` inside Effect code (e.g. `Effect.fail(new Error(...))` or the `catch` of `Effect.tryPromise`). Always fail with a tagged error. Reuse an existing one, or define a new one with `Schema.TaggedErrorClass` (or `Data.TaggedError` when it doesn't need to be serialised). A raw `Error` widens the error channel to `Error` / `unknown`, so `Effect.catchTag` loses the discriminant it needs to recover narrowly. The same applies to the signature of any function returning an Effect: its error type is a union of tagged errors, never a bare `Error`. Tagged errors are yieldable, so write `return yield* new ProductNotFound({ key })`.

```ts
export class FetchFailed extends Schema.TaggedErrorClass<FetchFailed>()("FetchFailed", {
  url: Schema.String,
  cause: Schema.Defect,
}) {}

// BAD: raw Error widens the failure channel
Effect.tryPromise({ try: () => fetch(url), catch: (e) => new Error(String(e)) });

// GOOD: tagged error — failure channel stays narrow and discriminated
Effect.tryPromise({ try: () => fetch(url), catch: (cause) => new FetchFailed({ url, cause }) });
```

---

Don't leave an Effect floating: every Effect is either `yield*`ed, returned, or assigned. When you return a failure from a generator, write `return yield*` so the types narrow.

---

Test Effect code with `@effect/vitest` (`it.effect`), providing test layers rather than mocking modules.

---

Before writing a changeset, explore other potentially related changesets so you don't duplicate effort.

You may write more than one changeset per commit, if the commit touches multiple user-facing behaviors.

---

When writing sandbox providers, don't share provider-specific code between them. Each provider — for instance Vercel and Daytona — integrates a different SDK and is a different concern; that integration logic must not be shared, even when two providers look similar today, because they will diverge.

The one exception is **pure, provider-agnostic utilities**: logic that references no provider SDK, no provider config, and whose behavior is purely a function of its inputs (e.g. a bounded string-tail buffer). These may live in a shared module. Test: if you can't tell which provider a function is for by reading it, it's a utility, not a shared abstraction.

---

`exec` with an `onLine` callback must call `onLine` in real-time as output arrives, not after the command completes. The orchestrator uses `onLine` callbacks to reset an idle timeout — if lines aren't emitted during execution, the timeout will fire prematurely or hangs won't be detected. Always use a streaming/WebSocket-based API from the underlying SDK, never execute-then-split.

---

Any public-facing properties or functions should have JSDOC comments explaining them.

---

Do not use lazy `import()`-style imports when importing Node built-ins. Just use imports.

---

Paths destined for the sandbox container (passed to `copyFileIn` / `copyFileOut` / `exec`, or stored as a sandbox cwd / projects dir) are always Linux paths. Use `posix.join` from `node:path`, not the bare platform-aware `join` — on Windows hosts the latter emits `\` separators, and `docker cp` / `podman cp` reject them silently (the run continues but data is lost).

Host-side paths (anything under `tmpdir()`, `hostRepoDir`, the host projects dir) should keep using platform-aware `join`.

---

When comparing two paths — `===`, `startsWith`, `Set.has`, `.includes`, etc. — normalize separators on both sides first (e.g. `p.replace(/\\/g, "/")`). `git` reports forward slashes on every platform, while `node:path.join`/`normalize` emit `\` on Windows, so a raw comparison between a git-derived path and a join-derived path silently fails on Windows. This is invisible on Linux/macOS CI because both sources emit `/` there, so it will not surface in tests unless you deliberately mix the two separator styles. When the result is returned for downstream `join`/fs use, re-apply platform-native `normalize` so callers get consistent separators; only the comparison needs forward slashes.

---

Optional parameters passed to functions should be scrutinised extremely carefully. They are a huge source of bugs (by omission). Prioritise correctness over backwards compatibility.

---

Every interactive prompt in the `sandcastle init` flow must be paired with a non-interactive CLI flag that resolves the same choice. They are linked: adding a new prompt without adding the matching flag breaks scripted / CI setup (no TTY → the prompt wedges or crashes), and adding a flag without wiring it into the prompt path leaves the interactive experience inconsistent. When stdin is not a TTY and the flag is absent for a prompt that would otherwise fire, fail fast with a message naming the missing flag rather than letting the prompt library crash. New prompt + new flag land in the same change.

---

If you need to provide an override to a function or modules' behavior during tests, don't use an `@internal` property, like so:

```ts
// BAD
type Example = {
  /** @internal Test-only override for the idle warning interval in milliseconds. Default: 60000 (1 minute). */
  readonly _idleWarningIntervalMs?: number;
  /** @internal Override for the host projects directory (for testing). */
  readonly _hostProjectsDir?: string;
  /** @internal Override for the sandbox projects directory (for testing). */
  readonly _sandboxProjectsDir?: string;
};
```

Instead, create a config layer using Effect for that function, then instantiate that differently in tests and in production. This helps keep the code cleaner. Don't make this layer optional - that adds more indirection to all layers of the code.

---

## Testing

### Core Principle

Tests verify behavior through public interfaces, not implementation details. Code can change entirely; tests shouldn't break unless behavior changed.

### Good Tests

Integration-style tests that exercise real code paths through public APIs. They describe _what_ the system does, not _how_.

```typescript
// GOOD: Tests observable behavior through the public interface
test("createUser makes user retrievable", async () => {
  const user = await createUser({ name: "Alice" });
  const retrieved = await getUser(user.id);
  expect(retrieved.name).toBe("Alice");
});
```

- Test behavior users/callers care about
- Use the public API only
- Survive internal refactors
- One logical assertion per test

### Bad Tests

```typescript
// BAD: Mocks internal collaborator, tests HOW not WHAT
test("checkout calls paymentService.process", async () => {
  const mockPayment = jest.mock(paymentService);
  await checkout(cart, payment);
  expect(mockPayment.process).toHaveBeenCalledWith(cart.total);
});

// BAD: Bypasses the interface to verify via database
test("createUser saves to database", async () => {
  await createUser({ name: "Alice" });
  const row = await db.query("SELECT * FROM users WHERE name = ?", ["Alice"]);
  expect(row).toBeDefined();
});
```

Red flags:

- Mocking internal collaborators (your own classes/modules)
- Testing private methods
- Asserting on call counts/order of internal calls
- Test breaks when refactoring without behavior change
- Test name describes HOW not WHAT
- Verifying through external means (e.g. querying a DB) instead of through the interface

### Mocking

Mock at **system boundaries** only:

- External APIs (payment, email, etc.)
- Time/randomness
- File system or databases when a real instance isn't practical

**Never mock your own classes/modules or internal collaborators.** If something is hard to test without mocking internals, redesign the interface.

Prefer SDK-style interfaces over generic fetchers at boundaries — each function is independently mockable with a single return shape, no conditional logic in test setup.

### TDD Workflow: Vertical Slices

Do NOT write all tests first, then all implementation. That produces tests that verify _imagined_ behavior and are insensitive to real changes.

Correct approach — one test, one implementation, repeat:

```
RED→GREEN: test1→impl1
RED→GREEN: test2→impl2
RED→GREEN: test3→impl3
```

Each test responds to what you learned from the previous cycle. Never refactor while RED — get to GREEN first.

## Interface Design

### Deep Modules

Prefer deep modules: small interface, deep implementation. A few methods with simple params hiding complex logic behind them.

Avoid shallow modules: large interface with many methods that just pass through to thin implementation. When designing, ask: can I reduce the number of methods? Can I simplify the parameters? Can I hide more complexity inside?

### Design for Testability

1. **Accept dependencies, don't create them** — pass external dependencies in rather than constructing them internally.
2. **Return results, don't produce side effects** — a function that returns a value is easier to test than one that mutates state.
3. **Small surface area** — fewer methods = fewer tests needed, fewer params = simpler test setup.