import { Context, Effect, Layer } from "effect";
import type { Doc, Id } from "../_generated/dataModel";
import type { ChangeSet, Group, Link, Product, Sticker, Viewport } from "../validators";
import { CanvasRepository } from "./canvas.repository";
import { CanvasNotFound, ForeignRows, InvalidInput, NotSignedIn } from "./errors";
import { FileRepository } from "./file.repository";
import { GroupRepository } from "./group.repository";
import { LinkRepository } from "./link.repository";
import { ProductRepository } from "./product.repository";
import { validateProduct } from "./product.service";
import { StickerRepository } from "./sticker.repository";
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
    const canvases = yield* CanvasRepository;
    const products = yield* ProductRepository;
    const stickers = yield* StickerRepository;
    const groups = yield* GroupRepository;
    const links = yield* LinkRepository;
    const files = yield* FileRepository;

    // Fails without revealing whether a Canvas the caller doesn't own exists.
    const owned = Effect.fnUntraced(function* (id: Id<"canvases">) {
      const user = yield* users.caller;
      const canvas = yield* canvases.get(id);
      if (!user || !canvas || canvas.owner !== user._id) return yield* new CanvasNotFound();
      return { user, canvas };
    });

    const load = Effect.fn("CanvasService.load")(function* (id: Id<"canvases">) {
      const { user, canvas } = yield* owned(id);
      // ponytail: all of the owner's Products, so search finds unplaced ones; split into a search query when catalogues grow.
      const ownedProducts = yield* products.ofOwner(user._id);
      const urls: Record<string, string> = {};
      for (const product of ownedProducts) {
        for (const key of [product.cutout, product.original, ...product.photos]) {
          if (!key || key in urls) continue;
          const file = yield* files.byKey(key);
          const url = file && file.owner === user._id ? yield* files.url(file.storageId) : null;
          if (url) urls[key] = url;
        }
      }
      return {
        viewport: canvas.viewport,
        products: ownedProducts.map(({ _id, _creationTime, owner, ...product }) => product),
        stickers: (yield* stickers.onCanvas(canvas._id)).map(({ _id, _creationTime, canvas, ...sticker }) => sticker),
        groups: (yield* groups.onCanvas(canvas._id)).map(({ _id, _creationTime, canvas, ...group }) => group),
        detachedLinks: (yield* links.onCanvas(canvas._id)).map(({ first, second }) => ({ first, second })),
        files: urls,
      };
    });

    const saveViewport = Effect.fn("CanvasService.saveViewport")(function* (id: Id<"canvases">, viewport: Viewport) {
      const { canvas } = yield* owned(id);
      if (![viewport.x, viewport.y, viewport.zoom].every(Number.isFinite) || viewport.zoom <= 0) {
        return yield* new InvalidInput({ message: "Invalid viewport." });
      }
      yield* canvases.setViewport(canvas._id, viewport);
    });

    const apply = Effect.fn("CanvasService.apply")(function* (id: Id<"canvases">, c: ChangeSet) {
      const { user, canvas } = yield* owned(id);
      const foreign = new ForeignRows();
      const onCanvas = (row: Doc<"stickers"> | Doc<"groups"> | null) => !row || row.canvas === canvas._id;

      for (const product of c.products) {
        yield* validateProduct(product);
        const row = yield* products.byKey(product.key);
        if (row && row.owner !== user._id) return yield* foreign;
        yield* products.save(user._id, product, row);
      }
      for (const sticker of c.stickers) {
        if (![sticker.x, sticker.y, sticker.width, sticker.height].every(Number.isFinite) || sticker.width <= 0 || sticker.height <= 0) {
          return yield* new InvalidInput({ message: "Invalid sticker geometry." });
        }
        const row = yield* stickers.byKey(sticker.key);
        if (!onCanvas(row)) return yield* foreign;
        yield* stickers.save(canvas._id, sticker, row);
      }
      for (const group of c.groups) {
        const row = yield* groups.byKey(group.key);
        if (!onCanvas(row)) return yield* foreign;
        yield* groups.save(canvas._id, group, row);
      }
      for (const link of c.links) {
        if (!(yield* links.find(canvas._id, link))) yield* links.add(canvas._id, link);
      }
      // Deletes are idempotent: a row the server never saw is already gone.
      for (const key of c.deletedStickers) {
        const row = yield* stickers.byKey(key);
        if (!onCanvas(row)) return yield* foreign;
        if (row) yield* stickers.remove(row._id);
      }
      for (const key of c.deletedGroups) {
        const row = yield* groups.byKey(key);
        if (!onCanvas(row)) return yield* foreign;
        if (row) yield* groups.remove(row._id);
      }
      for (const link of c.deletedLinks) {
        const row = yield* links.find(canvas._id, link);
        if (row) yield* links.remove(row._id);
      }
      for (const key of c.deletedProducts) {
        const row = yield* products.byKey(key);
        if (row && row.owner !== user._id) return yield* foreign;
        // Files stay: undo can bring the Product back. Only ProductService.remove deletes them.
        if (row) yield* products.remove(row._id);
      }

      // References must resolve inside the caller's own rows once the set is applied.
      for (const sticker of c.stickers) {
        const product = yield* products.byKey(sticker.product);
        if (!product || product.owner !== user._id) return yield* foreign;
      }
      for (const group of c.groups) {
        for (const member of group.members) {
          const sticker = yield* stickers.byKey(member);
          if (!sticker || sticker.canvas !== canvas._id) return yield* foreign;
        }
      }
    });

    return CanvasService.of({ load, saveViewport, apply });
  })).pipe(Layer.provide(UserService.layer));
}
