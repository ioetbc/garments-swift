import { v } from "convex/values";
import { action, internalMutation } from "./_generated/server";
import { runAction, runMutation } from "./lib/edge";
import { MatchService } from "./lib/match.service";
import { UserService } from "./lib/user.service";
import { candidate } from "./validators";

/**
 * Up to five Candidate matches for a base64-encoded JPEG Screenshot, searched from the
 * User's region (ISO 3166 alpha-2) when given. Signed-in Users only, within a daily limit.
 */
export const search = action({
  args: { image: v.string(), region: v.optional(v.string()) },
  returns: v.array(candidate),
  handler: (ctx, args) => runAction(ctx, MatchService.use((matches) => matches.search(args.image, args.region))),
});

/** Counts one search against the User's daily limit. False once it is used up. */
export const claim = internalMutation({
  args: { tokenIdentifier: v.string() },
  returns: v.boolean(),
  handler: (ctx, args) => runMutation(ctx, UserService.use((users) => users.claimSearch(args.tokenIdentifier))),
});
