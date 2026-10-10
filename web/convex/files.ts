import { v } from "convex/values";
import { Effect } from "effect";
import { mutation } from "./_generated/server";
import { runMutation } from "./lib/edge";
import { FileService } from "./lib/file.service";

/** A short-lived URL the client POSTs image bytes to. */
export const generateUploadUrl = mutation({
  args: {},
  returns: v.string(),
  handler: (ctx) => runMutation(ctx, FileService.use((files) => files.uploadUrl)),
});

/** Names an uploaded file by the client's key, so Products can reference it before the upload finishes. */
export const attach = mutation({
  args: { key: v.string(), storageId: v.id("_storage") },
  returns: v.null(),
  handler: (ctx, args) => runMutation(ctx, FileService.use((files) =>
    files.attach(args.key, args.storageId).pipe(Effect.as(null)))),
});
