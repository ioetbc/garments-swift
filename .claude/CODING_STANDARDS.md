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

Functions that return an Effect are written with `Effect.fn("name")(function* (...) {...})`, not as `() => Effect.gen(...)`. `Effect.fn` adds a tracing span and better stack traces. Use `Effect.fnUntraced` for small helpers that aren't worth a span. Plain `Effect.gen` is fine for inline code. Don't `.pipe` an `Effect.fn`. Pass the combinators as extra arguments instead.

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

Never use `new Error()` inside Effect code (e.g. `Effect.fail(new Error(...))` or the `catch` of `Effect.tryPromise`). Always fail with a tagged error. Reuse an existing one, or define a new one with `Schema.TaggedError` (or `Data.TaggedError` when it doesn't need to be serialised). A raw `Error` widens the error channel to `Error` / `unknown`, so `Effect.catchTag` loses the discriminant it needs to recover narrowly. The same applies to the signature of any function returning an Effect: its error type is a union of tagged errors, never a bare `Error`. Tagged errors are yieldable, so write `return yield* new ProductNotFound({ key })`.

```ts
export class FetchFailed extends Schema.TaggedError<FetchFailed>()("FetchFailed", {
  url: Schema.String,
  cause: Schema.Defect(),
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

## General

Any public-facing properties or functions should have JSDoc comments explaining them.

---

Do not use lazy `import()`-style imports when importing Node built-ins. Just use imports.

---

Optional parameters passed to functions should be scrutinised extremely carefully. They are a huge source of bugs (by omission). Prioritise correctness over backwards compatibility.

---

If you need to override a function's or module's behaviour in tests, don't add an `@internal` property for it, like so:

```ts
// BAD
type Example = {
  /** @internal Test-only override for the fetch timeout in milliseconds. */
  readonly _timeoutMs?: number;
};
```

Instead, create a config layer using Effect for that function, then provide it differently in tests and in production. Don't make this layer optional: that adds indirection to every layer of the code.

---

## Testing

See `TESTING_STANDARDS.md`.

## Interface Design

### Deep Modules

Prefer deep modules: small interface, deep implementation. A few methods with simple params hiding complex logic behind them.

Avoid shallow modules: large interface with many methods that just pass through to thin implementation. When designing, ask: can I reduce the number of methods? Can I simplify the parameters? Can I hide more complexity inside?

### Design for Testability

1. **Accept dependencies, don't create them** — pass external dependencies in rather than constructing them internally.
2. **Return results, don't produce side effects** — a function that returns a value is easier to test than one that mutates state.
3. **Small surface area** — fewer methods = fewer tests needed, fewer params = simpler test setup.