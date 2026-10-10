import { ConvexError, v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { action, internalMutation, type MutationCtx } from "./_generated/server";
import { callerIdentity } from "./lib/auth";

const BATCH = 200;

/**
 * Deletes the calling User: everything they own in Convex first, then their Clerk user.
 * Every step succeeds when there is nothing left, so a failure part way is finished by deleting again.
 */
export const remove = action({
  args: {},
  returns: v.null(),
  handler: async (ctx) => {
    const identity = await callerIdentity(ctx);
    while (!(await ctx.runMutation(internal.users.deleteBatch, { tokenIdentifier: identity.tokenIdentifier })));

    // Clerk revokes the Sign in with Apple token when it deletes the user.
    const response = await fetch(`https://api.clerk.com/v1/users/${encodeURIComponent(identity.subject)}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${process.env.CLERK_SECRET_KEY}` },
    });
    if (!response.ok && response.status !== 404) throw new ConvexError("Your data was deleted, but your sign-in could not be removed. Delete your account again to finish.");
    return null;
  },
});

/** Deletes up to one batch of the User's rows and files. Returns true once the User is gone. */
export const deleteBatch = internalMutation({
  args: { tokenIdentifier: v.string() },
  returns: v.boolean(),
  handler: async (ctx, { tokenIdentifier }) => {
    const user = await ctx.db.query("users").withIndex("by_token", (q) => q.eq("tokenIdentifier", tokenIdentifier)).unique();
    if (!user) return true;

    for (const canvas of await ctx.db.query("canvases").withIndex("by_owner", (q) => q.eq("owner", user._id)).take(BATCH)) {
      const rows = [
        ...await ctx.db.query("stickers").withIndex("by_canvas", (q) => q.eq("canvas", canvas._id)).take(BATCH),
        ...await ctx.db.query("groups").withIndex("by_canvas", (q) => q.eq("canvas", canvas._id)).take(BATCH),
        ...await ctx.db.query("detachedLinks").withIndex("by_canvas", (q) => q.eq("canvas", canvas._id)).take(BATCH),
      ];
      if (rows.length) return await drop(ctx, rows.map((r) => r._id));
      await ctx.db.delete(canvas._id);
    }
    const products = await ctx.db.query("products").withIndex("by_owner", (q) => q.eq("owner", user._id)).take(BATCH);
    if (products.length) return await drop(ctx, products.map((p) => p._id));
    const files = await ctx.db.query("files").withIndex("by_owner", (q) => q.eq("owner", user._id)).take(BATCH);
    if (files.length) {
      for (const file of files) await ctx.storage.delete(file.storageId);
      return await drop(ctx, files.map((f) => f._id));
    }
    await ctx.db.delete(user._id);
    return true;
  },
});

async function drop(ctx: MutationCtx, ids: Id<"stickers" | "groups" | "detachedLinks" | "products" | "files">[]) {
  for (const id of ids) await ctx.db.delete(id);
  return false;
}
