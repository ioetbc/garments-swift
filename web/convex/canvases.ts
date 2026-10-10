import { v } from "convex/values";
import { Effect } from "effect";
import { mutation, query } from "./_generated/server";
import { CanvasService } from "./lib/canvas.service";
import { runMutation, runQuery } from "./lib/edge";
import { UserService } from "./lib/user.service";
import { changeSet, viewport } from "./validators";

/** Resolves the caller's Canvas, creating the User and Canvas on first request. */
export const start = mutation({
  args: {},
  returns: v.id("canvases"),
  handler: (ctx) => runMutation(ctx, UserService.use((users) => users.ensureCaller.pipe(Effect.map((caller) => caller.canvas)))),
});

/**
 * The whole Canvas: Viewport, Stickers, Groups, detached links, and every one of
 * the owner's Products with URLs for their files.
 */
export const load = query({
  args: { canvas: v.id("canvases") },
  handler: (ctx, args) => runQuery(ctx, CanvasService.use((canvases) => canvases.load(args.canvas))),
});

/** Saves where the Canvas was last viewed. Kept apart from edits so it never enters undo. */
export const saveViewport = mutation({
  args: { canvas: v.id("canvases"), viewport },
  returns: v.null(),
  handler: (ctx, args) => runMutation(ctx, CanvasService.use((canvases) =>
    canvases.saveViewport(args.canvas, args.viewport).pipe(Effect.as(null)))),
});

/**
 * Applies one committed edit's row upserts and deletes in a single transaction.
 * Last write wins per row. Any id belonging to someone else rejects the whole set.
 */
export const apply = mutation({
  args: { canvas: v.id("canvases"), changes: changeSet },
  returns: v.null(),
  handler: (ctx, args) => runMutation(ctx, CanvasService.use((canvases) =>
    canvases.apply(args.canvas, args.changes).pipe(Effect.as(null)))),
});
