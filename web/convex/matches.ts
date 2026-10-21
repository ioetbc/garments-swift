import { v } from "convex/values";
import { action } from "./_generated/server";
import { runAction } from "./lib/edge";
import { MatchService } from "./lib/match.service";
import { candidate } from "./validators";

/**
 * The listing a base64-encoded JPEG Screenshot most likely shows, or null, searched from the
 * User's region (ISO 3166 alpha-2) when given. Signed-in Users only.
 */
export const search = action({
  args: { image: v.string(), region: v.optional(v.string()) },
  returns: v.union(candidate, v.null()),
  handler: (ctx, args) => runAction(ctx, MatchService.use((matches) => matches.search(args.image, args.region))),
});
