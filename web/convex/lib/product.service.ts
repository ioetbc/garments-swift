import { Context, Effect, Layer } from "effect";
import type { Product } from "../validators";
import { Db } from "./db";
import { InvalidInput, NotSignedIn, ProductNotFound } from "./errors";
import { UserService } from "./user.service";

/** Rejects values the validators cannot express: integer minor units and ISO 4217 codes. */
export const validateProduct = Effect.fnUntraced(function* (p: Product) {
  if (p.price && (!Number.isSafeInteger(p.price.amount) || p.price.amount < 0 || !/^[A-Z]{3}$/.test(p.price.currency))) {
    return yield* new InvalidInput({ message: "Price must be a non-negative whole number of minor units with an ISO 4217 currency." });
  }
  if (!Number.isFinite(p.aspect) || p.aspect <= 0) return yield* new InvalidInput({ message: "Invalid aspect ratio." });
});

/** Product rules that span its Stickers and files. */
export class ProductService extends Context.Service<ProductService, {
  /** Deletes a Product, every Sticker of it on any of the owner's Canvases, and its stored files. */
  remove(key: string): Effect.Effect<void, NotSignedIn | ProductNotFound>;
}>()("garms/ProductService") {
  static readonly layer = Layer.effect(ProductService, Effect.gen(function* () {
    const users = yield* UserService;
    const db = yield* Db;

    const remove = Effect.fn("ProductService.remove")(function* (key: string) {
      const user = yield* users.caller;
      const product = yield* db.byKey("products", key);
      if (!product) return;
      if (!user || product.owner !== user._id) return yield* new ProductNotFound();

      const placed = yield* db.stickersOf(product.key);
      const removed = new Set(placed.map((s) => s.key));
      for (const canvas of new Set(placed.map((s) => s.canvas))) {
        for (const group of yield* db.onCanvas("groups", canvas)) {
          if (group.members.some((m) => removed.has(m))) {
            yield* db.patch(group._id, { members: group.members.filter((m) => !removed.has(m)) });
          }
        }
        for (const link of yield* db.onCanvas("detachedLinks", canvas)) {
          if (removed.has(link.first) || removed.has(link.second)) yield* db.remove(link);
        }
      }
      for (const sticker of placed) yield* db.remove(sticker);

      for (const fileKey of new Set([product.cutout, product.original, ...product.photos])) {
        if (!fileKey) continue;
        const file = yield* db.byKey("files", fileKey);
        if (file && file.owner === user._id) yield* db.remove(file);
      }
      yield* db.remove(product);
    });

    return ProductService.of({ remove });
  }));
}
