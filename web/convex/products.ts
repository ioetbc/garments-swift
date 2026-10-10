import { ConvexError, v } from "convex/values";
import { mutation } from "./_generated/server";
import { findUser } from "./lib/auth";

/** Deletes a Product, every Sticker of it on any of the owner's Canvases, and its stored files. */
export const remove = mutation({
  args: { product: v.string() },
  returns: v.null(),
  handler: async (ctx, args) => {
    const user = await findUser(ctx);
    const product = await ctx.db.query("products").withIndex("by_key", (q) => q.eq("key", args.product)).unique();
    if (!product) return null;
    if (!user || product.owner !== user._id) throw new ConvexError("Product not found.");

    const stickers = await ctx.db.query("stickers").withIndex("by_product", (q) => q.eq("product", product.key)).collect();
    const removed = new Set(stickers.map((s) => s.key));
    for (const canvas of new Set(stickers.map((s) => s.canvas))) {
      for (const group of await ctx.db.query("groups").withIndex("by_canvas", (q) => q.eq("canvas", canvas)).collect()) {
        if (group.members.some((m) => removed.has(m))) {
          await ctx.db.patch(group._id, { members: group.members.filter((m) => !removed.has(m)) });
        }
      }
      for (const link of await ctx.db.query("detachedLinks").withIndex("by_canvas", (q) => q.eq("canvas", canvas)).collect()) {
        if (removed.has(link.first) || removed.has(link.second)) await ctx.db.delete(link._id);
      }
    }
    for (const sticker of stickers) await ctx.db.delete(sticker._id);

    for (const key of new Set([product.cutout, product.original, ...product.photos])) {
      if (!key) continue;
      const file = await ctx.db.query("files").withIndex("by_key", (q) => q.eq("key", key)).unique();
      if (!file || file.owner !== user._id) continue;
      await ctx.storage.delete(file.storageId);
      await ctx.db.delete(file._id);
    }
    await ctx.db.delete(product._id);
    return null;
  },
});
