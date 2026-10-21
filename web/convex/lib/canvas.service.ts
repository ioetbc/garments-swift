import type { WithoutSystemFields } from "convex/server";
import { Context, Effect, Layer } from "effect";
import type { Doc, Id } from "../_generated/dataModel";
import type { ChangeSet, Group, Link, Product, Sticker, Viewport } from "../validators";
import { Db } from "./db";
import { CanvasNotFound, ForeignRows, InvalidInput, NotSignedIn } from "./errors";
import { validateProduct } from "./product.service";
import { UserService } from "./user.service";

/** Everything the client needs to draw a Canvas. */
export type LoadedCanvas = {
  readonly viewport: Viewport;
  readonly products: Array<Product>;
  readonly stickers: Array<Sticker>;
  readonly groups: Array<Group>;
  readonly detachedLinks: Array<Link>;
  /** URL of each file the Products reference, by file key. */
  readonly files: Record<string, string>;
};

/** Reading and editing a Canvas its owner can see. */
export class CanvasService extends Context.Service<CanvasService, {
  /**
   * The whole Canvas: Viewport, Stickers, Groups, detached links, and every one of
   * the owner's Products with URLs for their files.
   */
  load(id: Id<"canvases">): Effect.Effect<LoadedCanvas, NotSignedIn | CanvasNotFound>;
  /** Saves where the Canvas was last viewed. */
  saveViewport(id: Id<"canvases">, viewport: Viewport): Effect.Effect<void, NotSignedIn | CanvasNotFound | InvalidInput>;
  /**
   * Applies one committed edit's row upserts and deletes. Last write wins per row.
   * Any id belonging to someone else rejects the whole set.
   */
  apply(id: Id<"canvases">, changes: ChangeSet): Effect.Effect<void, NotSignedIn | CanvasNotFound | InvalidInput | ForeignRows>;
}>()("garms/CanvasService") {
  static readonly layer = Layer.effect(CanvasService, Effect.gen(function* () {
    const users = yield* UserService;
    const db = yield* Db;

    // Fails without revealing whether a Canvas the caller doesn't own exists.
    const owned = Effect.fnUntraced(function* (id: Id<"canvases">) {
      const user = yield* users.caller;
      const canvas = yield* db.get(id);
      if (!user || !canvas || canvas.owner !== user._id) return yield* new CanvasNotFound();
      return { user, canvas };
    });

    const load = Effect.fn("CanvasService.load")(function* (id: Id<"canvases">) {
      const { user, canvas } = yield* owned(id);
      // ponytail: all of the owner's Products, so search finds unplaced ones; split into a search query when catalogues grow.
      const ownedProducts = yield* db.ofOwner("products", user._id);
      const urls: Record<string, string> = {};
      for (const product of ownedProducts) {
        for (const key of [product.cutout, product.original, ...product.photos]) {
          if (!key || key in urls) continue;
          const file = yield* db.byKey("files", key);
          const url = file && file.owner === user._id ? yield* db.fileUrl(file.storageId) : null;
          if (url) urls[key] = url;
        }
      }
      return {
        viewport: canvas.viewport,
        products: ownedProducts.map(({ _id, _creationTime, owner, ...product }) => product),
        stickers: (yield* db.onCanvas("stickers", canvas._id)).map(({ _id, _creationTime, canvas, ...sticker }) => sticker),
        groups: (yield* db.onCanvas("groups", canvas._id)).map(({ _id, _creationTime, canvas, ...group }) => group),
        detachedLinks: (yield* db.onCanvas("detachedLinks", canvas._id)).map(({ first, second }) => ({ first, second })),
        files: urls,
      };
    });

    const saveViewport = Effect.fn("CanvasService.saveViewport")(function* (id: Id<"canvases">, viewport: Viewport) {
      const { canvas } = yield* owned(id);
      if (![viewport.x, viewport.y, viewport.zoom].every(Number.isFinite) || viewport.zoom <= 0) {
        return yield* new InvalidInput({ message: "Invalid viewport." });
      }
      yield* db.patch(canvas._id, { viewport });
    });

    const apply = Effect.fn("CanvasService.apply")(function* (id: Id<"canvases">, c: ChangeSet) {
      const { user, canvas } = yield* owned(id);
      const foreign = new ForeignRows();
      // Upserts `value` over the keyed row, or deletes the row when null. Fails on a row of another User or Canvas.
      const write = Effect.fnUntraced(function* <T extends "products" | "stickers" | "groups">(
        table: T, key: string, value: WithoutSystemFields<Doc<T>> | null,
      ) {
        const row: Doc<T> | null = yield* db.byKey(table, key);
        const r = row as Doc<"products" | "stickers" | "groups"> | null;
        if (r && ("owner" in r ? r.owner !== user._id : r.canvas !== canvas._id)) return yield* foreign;
        if (value) yield* db.upsert(table, row, value);
        else if (r) yield* db.remove(r);
      });

      for (const product of c.products) {
        yield* validateProduct(product);
        yield* write("products", product.key, { owner: user._id, ...product });
      }
      for (const sticker of c.stickers) {
        if (![sticker.x, sticker.y, sticker.width, sticker.height].every(Number.isFinite) || sticker.width <= 0 || sticker.height <= 0) {
          return yield* new InvalidInput({ message: "Invalid sticker geometry." });
        }
        yield* write("stickers", sticker.key, { canvas: canvas._id, ...sticker });
      }
      for (const group of c.groups) yield* write("groups", group.key, { canvas: canvas._id, ...group });
      for (const link of c.links) {
        if (!(yield* db.link(canvas._id, link))) yield* db.insert("detachedLinks", { canvas: canvas._id, ...link });
      }
      // Deletes are idempotent: a row the server never saw is already gone.
      for (const key of c.deletedStickers) yield* write("stickers", key, null);
      for (const key of c.deletedGroups) yield* write("groups", key, null);
      for (const link of c.deletedLinks) {
        const row = yield* db.link(canvas._id, link);
        if (row) yield* db.remove(row);
      }
      // Files stay: undo can bring the Product back. Only ProductService.remove deletes them.
      for (const key of c.deletedProducts) yield* write("products", key, null);

      // References must resolve inside the caller's own rows once the set is applied.
      for (const sticker of c.stickers) {
        const product = yield* db.byKey("products", sticker.product);
        if (!product || product.owner !== user._id) return yield* foreign;
      }
      for (const group of c.groups) {
        for (const member of group.members) {
          const sticker = yield* db.byKey("stickers", member);
          if (!sticker || sticker.canvas !== canvas._id) return yield* foreign;
        }
      }
    });

    return CanvasService.of({ load, saveViewport, apply });
  }));
}
