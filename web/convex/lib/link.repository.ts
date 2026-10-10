import { Context, Effect, Layer } from "effect";
import type { Doc, Id } from "../_generated/dataModel";
import type { Link } from "../validators";
import { ConvexContext } from "./context";

/** Stored detached links: pairs of Stickers on a Canvas that must not re-join by proximity. */
export class LinkRepository extends Context.Service<LinkRepository, {
  find(canvas: Id<"canvases">, link: Link): Effect.Effect<Doc<"detachedLinks"> | null>;
  onCanvas(canvas: Id<"canvases">): Effect.Effect<Array<Doc<"detachedLinks">>>;
  add(canvas: Id<"canvases">, link: Link): Effect.Effect<void>;
  remove(id: Id<"detachedLinks">): Effect.Effect<void>;
  /** Deletes up to `limit` of the Canvas's rows, returning how many it deleted. */
  removeOnCanvas(canvas: Id<"canvases">, limit: number): Effect.Effect<number>;
}>()("garms/LinkRepository") {
  static readonly layer = Layer.effect(LinkRepository, Effect.gen(function* () {
    const { read, write } = yield* ConvexContext;
    return LinkRepository.of({
      find: (canvas, link) => read((ctx) => ctx.db.query("detachedLinks")
        .withIndex("by_canvas", (q) => q.eq("canvas", canvas).eq("first", link.first).eq("second", link.second))
        .unique()),
      onCanvas: (canvas) => read((ctx) => ctx.db.query("detachedLinks").withIndex("by_canvas", (q) => q.eq("canvas", canvas)).collect()),
      add: (canvas, link) => write(async (ctx) => { await ctx.db.insert("detachedLinks", { canvas, ...link }); }),
      remove: (id) => write((ctx) => ctx.db.delete(id)),
      removeOnCanvas: (canvas, limit) => write(async (ctx) => {
        const rows = await ctx.db.query("detachedLinks").withIndex("by_canvas", (q) => q.eq("canvas", canvas)).take(limit);
        for (const row of rows) await ctx.db.delete(row._id);
        return rows.length;
      }),
    });
  }));
}
