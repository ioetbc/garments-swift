import { Context, Effect, Layer } from "effect";
import type { Doc, Id } from "../_generated/dataModel";
import type { Sticker } from "../validators";
import { ConvexContext } from "./context";

/** Stored Stickers, addressed by their client-generated key. */
export class StickerRepository extends Context.Service<StickerRepository, {
  byKey(key: string): Effect.Effect<Doc<"stickers"> | null>;
  onCanvas(canvas: Id<"canvases">): Effect.Effect<Array<Doc<"stickers">>>;
  /** Every Sticker of a Product, across Canvases. */
  ofProduct(product: string): Effect.Effect<Array<Doc<"stickers">>>;
  /** Writes the Sticker over `existing`, the row `byKey` found for its key, or inserts it when null. */
  save(canvas: Id<"canvases">, sticker: Sticker, existing: Doc<"stickers"> | null): Effect.Effect<void>;
  remove(id: Id<"stickers">): Effect.Effect<void>;
}>()("garms/StickerRepository") {
  static readonly layer = Layer.effect(StickerRepository, Effect.gen(function* () {
    const { read, write } = yield* ConvexContext;
    return StickerRepository.of({
      byKey: (key) => read((ctx) => ctx.db.query("stickers").withIndex("by_key", (q) => q.eq("key", key)).unique()),
      onCanvas: (canvas) => read((ctx) => ctx.db.query("stickers").withIndex("by_canvas", (q) => q.eq("canvas", canvas)).collect()),
      ofProduct: (product) => read((ctx) => ctx.db.query("stickers").withIndex("by_product", (q) => q.eq("product", product)).collect()),
      save: (canvas, sticker, existing) => write(async (ctx) => {
        if (existing) await ctx.db.replace(existing._id, { canvas, ...sticker });
        else await ctx.db.insert("stickers", { canvas, ...sticker });
      }),
      remove: (id) => write((ctx) => ctx.db.delete(id)),
    });
  }));
}
