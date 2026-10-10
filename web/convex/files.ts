import { ConvexError, v } from "convex/values";
import { mutation } from "./_generated/server";
import { callerToken, ensureUser } from "./lib/auth";

/** A short-lived URL the client POSTs image bytes to. */
export const generateUploadUrl = mutation({
  args: {},
  returns: v.string(),
  handler: async (ctx) => {
    await ensureUser(ctx, await callerToken(ctx));
    return await ctx.storage.generateUploadUrl();
  },
});

/** Names an uploaded file by the client's key, so Products can reference it before the upload finishes. */
export const attach = mutation({
  args: { key: v.string(), storageId: v.id("_storage") },
  returns: v.null(),
  handler: async (ctx, args) => {
    const { user } = await ensureUser(ctx, await callerToken(ctx));
    const existing = await ctx.db.query("files").withIndex("by_key", (q) => q.eq("key", args.key)).unique();
    if (existing && existing.owner !== user) throw new ConvexError("File key is taken.");
    const claimed = await ctx.db.query("files").withIndex("by_storage", (q) => q.eq("storageId", args.storageId)).unique();
    if (claimed && claimed.key !== args.key) throw new ConvexError("File is already attached.");
    if (existing) {
      if (existing.storageId !== args.storageId) await ctx.storage.delete(existing.storageId);
      await ctx.db.patch(existing._id, { storageId: args.storageId });
    } else {
      await ctx.db.insert("files", { owner: user, key: args.key, storageId: args.storageId });
    }
    return null;
  },
});
