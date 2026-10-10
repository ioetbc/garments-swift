import { Context, Effect, Layer } from "effect";
import type { Doc, Id } from "../_generated/dataModel";
import type { Viewport } from "../validators";
import { ConvexContext } from "./context";

/** Stored Canvases and their Viewports. */
export class CanvasRepository extends Context.Service<CanvasRepository, {
  get(id: Id<"canvases">): Effect.Effect<Doc<"canvases"> | null>;
  /** The User's first Canvas. */
  firstOf(owner: Id<"users">): Effect.Effect<Doc<"canvases"> | null>;
  create(owner: Id<"users">, viewport: Viewport): Effect.Effect<Id<"canvases">>;
  setViewport(id: Id<"canvases">, viewport: Viewport): Effect.Effect<void>;
}>()("garms/CanvasRepository") {
  static readonly layer = Layer.effect(CanvasRepository, Effect.gen(function* () {
    const { read, write } = yield* ConvexContext;
    return CanvasRepository.of({
      get: (id) => read((ctx) => ctx.db.get(id)),
      firstOf: (owner) => read((ctx) => ctx.db.query("canvases").withIndex("by_owner", (q) => q.eq("owner", owner)).first()),
      create: (owner, viewport) => write((ctx) => ctx.db.insert("canvases", { owner, viewport })),
      setViewport: (id, viewport) => write((ctx) => ctx.db.patch(id, { viewport })),
    });
  }));
}
