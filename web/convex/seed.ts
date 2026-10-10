import { v } from "convex/values";
import { Effect } from "effect";
import { internalMutation } from "./_generated/server";
import { runMutation } from "./lib/edge";
import { SeedService } from "./lib/seed.service";
import { sample } from "./validators";

// Internal only: run from a developer machine with `npx convex run`, never reachable from the app.

/** Upload URL for one sample image. */
export const uploadUrl = internalMutation({
  args: {},
  returns: v.string(),
  handler: (ctx) => runMutation(ctx, SeedService.use((seed) => seed.uploadUrl)),
});

/**
 * Seeds the named account's empty Canvas with `count` Stickers cycling through
 * the sample Products, arranged in repeatable clusters that each form a Group.
 */
export const run = internalMutation({
  args: { tokenIdentifier: v.string(), count: v.optional(v.number()), samples: v.array(sample) },
  returns: v.null(),
  handler: (ctx, args) => runMutation(ctx, SeedService.use((seed) =>
    seed.seed(args.tokenIdentifier, args.count ?? 100, args.samples).pipe(Effect.as(null)))),
});
