import { Context, Effect, Layer } from "effect";
import type { Doc, Id } from "../_generated/dataModel";
import type { Product } from "../validators";
import { ConvexContext } from "./context";

/** Stored Products, addressed by their client-generated key. */
export class ProductRepository extends Context.Service<ProductRepository, {
  byKey(key: string): Effect.Effect<Doc<"products"> | null>;
  ofOwner(owner: Id<"users">): Effect.Effect<Array<Doc<"products">>>;
  /** Writes the Product over `existing`, the row `byKey` found for its key, or inserts it when null. */
  save(owner: Id<"users">, product: Product, existing: Doc<"products"> | null): Effect.Effect<void>;
  remove(id: Id<"products">): Effect.Effect<void>;
}>()("garms/ProductRepository") {
  static readonly layer = Layer.effect(ProductRepository, Effect.gen(function* () {
    const { read, write } = yield* ConvexContext;
    return ProductRepository.of({
      byKey: (key) => read((ctx) => ctx.db.query("products").withIndex("by_key", (q) => q.eq("key", key)).unique()),
      ofOwner: (owner) => read((ctx) => ctx.db.query("products").withIndex("by_owner", (q) => q.eq("owner", owner)).collect()),
      save: (owner, product, existing) => write(async (ctx) => {
        if (existing) await ctx.db.replace(existing._id, { owner, ...product });
        else await ctx.db.insert("products", { owner, ...product });
      }),
      remove: (id) => write((ctx) => ctx.db.delete(id)),
    });
  }));
}
