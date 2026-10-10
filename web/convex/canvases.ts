import { ConvexError, v } from "convex/values";
import type { Id } from "./_generated/dataModel";
import { mutation, query, type QueryCtx } from "./_generated/server";
import { callerToken, ensureUser, ownedCanvas } from "./lib/auth";
import { validateProduct } from "./lib/products";
import { changeSet, viewport } from "./validators";

/** Resolves the caller's Canvas, creating the User and Canvas on first request. */
export const start = mutation({
  args: {},
  returns: v.id("canvases"),
  handler: async (ctx) => (await ensureUser(ctx, await callerToken(ctx))).canvas,
});

/**
 * The whole Canvas: Viewport, Stickers, Groups, detached links, and every one of
 * the owner's Products with URLs for their files.
 */
export const load = query({
  args: { canvas: v.id("canvases") },
  handler: async (ctx, args) => {
    const { user, canvas } = await ownedCanvas(ctx, args.canvas);
    // ponytail: all of the owner's Products, so search finds unplaced ones; split into a search query when catalogues grow.
    const products = await ctx.db.query("products").withIndex("by_owner", (q) => q.eq("owner", user._id)).collect();
    const files: Record<string, string> = {};
    for (const product of products) {
      for (const key of [product.cutout, product.original, ...product.photos]) {
        if (!key || key in files) continue;
        const file = await ctx.db.query("files").withIndex("by_key", (q) => q.eq("key", key)).unique();
        const url = file && file.owner === user._id ? await ctx.storage.getUrl(file.storageId) : null;
        if (url) files[key] = url;
      }
    }
    return {
      viewport: canvas.viewport,
      products: products.map(({ _id, _creationTime, owner, ...product }) => product),
      stickers: (await ctx.db.query("stickers").withIndex("by_canvas", (q) => q.eq("canvas", canvas._id)).collect()).map(({ _id, _creationTime, canvas, ...sticker }) => sticker),
      groups: (await ctx.db.query("groups").withIndex("by_canvas", (q) => q.eq("canvas", canvas._id)).collect()).map(({ _id, _creationTime, canvas, ...group }) => group),
      detachedLinks: (await ctx.db.query("detachedLinks").withIndex("by_canvas", (q) => q.eq("canvas", canvas._id)).collect()).map(({ first, second }) => ({ first, second })),
      files,
    };
  },
});

/** Saves where the Canvas was last viewed. Kept apart from edits so it never enters undo. */
export const saveViewport = mutation({
  args: { canvas: v.id("canvases"), viewport },
  returns: v.null(),
  handler: async (ctx, args) => {
    const { canvas } = await ownedCanvas(ctx, args.canvas);
    if (![args.viewport.x, args.viewport.y, args.viewport.zoom].every(Number.isFinite) || args.viewport.zoom <= 0) {
      throw new ConvexError("Invalid viewport.");
    }
    await ctx.db.patch(canvas._id, { viewport: args.viewport });
    return null;
  },
});

/**
 * Applies one committed edit's row upserts and deletes in a single transaction.
 * Last write wins per row. Any id belonging to someone else rejects the whole set.
 */
export const apply = mutation({
  args: { canvas: v.id("canvases"), changes: changeSet },
  returns: v.null(),
  handler: async (ctx, args) => {
    const { user, canvas } = await ownedCanvas(ctx, args.canvas);
    const c = args.changes;
    const foreign = () => { throw new ConvexError("Change set references rows you do not own."); };

    for (const product of c.products) {
      validateProduct(product);
      const row = await productByKey(ctx, product.key);
      if (row && row.owner !== user._id) foreign();
      if (row) await ctx.db.replace(row._id, { owner: user._id, ...product });
      else await ctx.db.insert("products", { owner: user._id, ...product });
    }
    for (const sticker of c.stickers) {
      if (![sticker.x, sticker.y, sticker.width, sticker.height].every(Number.isFinite) || sticker.width <= 0 || sticker.height <= 0) {
        throw new ConvexError("Invalid sticker geometry.");
      }
      const row = await stickerByKey(ctx, sticker.key);
      if (row && row.canvas !== canvas._id) foreign();
      if (row) await ctx.db.replace(row._id, { canvas: canvas._id, ...sticker });
      else await ctx.db.insert("stickers", { canvas: canvas._id, ...sticker });
    }
    for (const group of c.groups) {
      const row = await groupByKey(ctx, group.key);
      if (row && row.canvas !== canvas._id) foreign();
      if (row) await ctx.db.replace(row._id, { canvas: canvas._id, ...group });
      else await ctx.db.insert("groups", { canvas: canvas._id, ...group });
    }
    for (const link of c.links) {
      if (!(await findLink(ctx, canvas._id, link))) await ctx.db.insert("detachedLinks", { canvas: canvas._id, ...link });
    }
    // Deletes are idempotent: a row the server never saw is already gone.
    for (const key of c.deletedStickers) {
      const row = await stickerByKey(ctx, key);
      if (row && row.canvas !== canvas._id) foreign();
      if (row) await ctx.db.delete(row._id);
    }
    for (const key of c.deletedGroups) {
      const row = await groupByKey(ctx, key);
      if (row && row.canvas !== canvas._id) foreign();
      if (row) await ctx.db.delete(row._id);
    }
    for (const link of c.deletedLinks) {
      const row = await findLink(ctx, canvas._id, link);
      if (row) await ctx.db.delete(row._id);
    }
    for (const key of c.deletedProducts) {
      const row = await productByKey(ctx, key);
      if (row && row.owner !== user._id) foreign();
      // Files stay: undo can bring the Product back. Only products.remove deletes them.
      if (row) await ctx.db.delete(row._id);
    }

    // References must resolve inside the caller's own rows once the set is applied.
    for (const sticker of c.stickers) {
      const product = await productByKey(ctx, sticker.product);
      if (!product || product.owner !== user._id) foreign();
    }
    for (const group of c.groups) {
      for (const member of group.members) {
        const sticker = await stickerByKey(ctx, member);
        if (!sticker || sticker.canvas !== canvas._id) foreign();
      }
    }
    return null;
  },
});

const productByKey = (ctx: QueryCtx, key: string) =>
  ctx.db.query("products").withIndex("by_key", (q) => q.eq("key", key)).unique();
const stickerByKey = (ctx: QueryCtx, key: string) =>
  ctx.db.query("stickers").withIndex("by_key", (q) => q.eq("key", key)).unique();
const groupByKey = (ctx: QueryCtx, key: string) =>
  ctx.db.query("groups").withIndex("by_key", (q) => q.eq("key", key)).unique();

async function findLink(ctx: QueryCtx, canvas: Id<"canvases">, link: { first: string; second: string }) {
  return await ctx.db.query("detachedLinks")
    .withIndex("by_canvas", (q) => q.eq("canvas", canvas).eq("first", link.first).eq("second", link.second))
    .unique();
}
