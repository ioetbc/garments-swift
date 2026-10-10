import { ConvexError } from "convex/values";
import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";

/**
 * Identifies the caller from the auth identity. With no identity, a dev
 * deployment may act as the single User named by GARMS_DEV_USER; that variable
 * is never set on prod and is removed when Clerk lands.
 */
export async function callerToken(ctx: QueryCtx): Promise<string> {
  const identity = await ctx.auth.getUserIdentity();
  if (identity) return identity.tokenIdentifier;
  const devUser = process.env.GARMS_DEV_USER;
  if (devUser) return `dev|${devUser}`;
  throw new ConvexError("Not signed in.");
}

/** The calling User, or null before their first request created them. */
export async function findUser(ctx: QueryCtx): Promise<Doc<"users"> | null> {
  const token = await callerToken(ctx);
  return await ctx.db.query("users").withIndex("by_token", (q) => q.eq("tokenIdentifier", token)).unique();
}

/** The User for this token, created with one Canvas and its Recent uploads Group on first request. */
export async function ensureUser(ctx: MutationCtx, tokenIdentifier: string): Promise<{ user: Id<"users">; canvas: Id<"canvases"> }> {
  const existing = await ctx.db.query("users").withIndex("by_token", (q) => q.eq("tokenIdentifier", tokenIdentifier)).unique();
  if (existing) {
    const canvas = await ctx.db.query("canvases").withIndex("by_owner", (q) => q.eq("owner", existing._id)).first();
    if (canvas) return { user: existing._id, canvas: canvas._id };
  }
  const user = existing?._id ?? (await ctx.db.insert("users", { tokenIdentifier }));
  const canvas = await ctx.db.insert("canvases", { owner: user, viewport: { x: 0, y: 0, zoom: 1 } });
  await ctx.db.insert("groups", {
    canvas, key: crypto.randomUUID(), members: [], name: "Recent uploads",
    colour: { red: 0.22, green: 1, blue: 0.08 }, isRecentUploads: true, emptyCenter: { x: 0, y: 0 },
  });
  return { user, canvas };
}

/** The Canvas, if the caller owns it; otherwise throws without revealing whether it exists. */
export async function ownedCanvas(ctx: QueryCtx, id: Id<"canvases">): Promise<{ user: Doc<"users">; canvas: Doc<"canvases"> }> {
  const user = await findUser(ctx);
  const canvas = await ctx.db.get(id);
  if (!user || !canvas || canvas.owner !== user._id) throw new ConvexError("Canvas not found.");
  return { user, canvas };
}
