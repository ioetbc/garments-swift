import { Context, Data, Effect, Layer } from "effect";
import type { MutationCtx, QueryCtx } from "../_generated/server";

/** A repository tried to write while serving a query. A bug, so a defect rather than a failure. */
export class WriteInQuery extends Data.TaggedError("WriteInQuery") {}

/** The running handler's Convex context. Only repositories and Auth use it. Convex failures are defects. */
export class ConvexContext extends Context.Service<ConvexContext, {
  read<A>(f: (ctx: QueryCtx) => Promise<A>): Effect.Effect<A>;
  /** Dies with WriteInQuery when the handler is a query, which has no writer. */
  write<A>(f: (ctx: MutationCtx) => Promise<A>): Effect.Effect<A>;
}>()("garms/ConvexContext") {
  /** For query handlers: reads only. */
  static query = (ctx: QueryCtx) => Layer.succeed(ConvexContext, ConvexContext.of({
    read: (f) => Effect.promise(() => f(ctx)),
    write: () => Effect.die(new WriteInQuery()),
  }));

  /** For mutation handlers: reads and writes. */
  static mutation = (ctx: MutationCtx) => Layer.succeed(ConvexContext, ConvexContext.of({
    read: (f) => Effect.promise(() => f(ctx)),
    write: (f) => Effect.promise(() => f(ctx)),
  }));
}
