import { v } from "convex/values";
import { Effect } from "effect";
import { action, internalMutation } from "./_generated/server";
import { AccountService, deleteBatch as deleteUserBatch } from "./lib/account.service";
import { runAction, runMutation } from "./lib/edge";

/**
 * Deletes the calling User: everything they own in Convex first, then their Clerk user.
 * Every step succeeds when there is nothing left, so a failure part way is finished by deleting again.
 */
export const remove = action({
  args: {},
  returns: v.null(),
  handler: (ctx): Promise<null> => runAction(ctx, AccountService.use((accounts) => accounts.remove.pipe(Effect.as(null)))),
});

/** Deletes up to one batch of the User's rows and files. Returns true once the User is gone. */
export const deleteBatch = internalMutation({
  args: { tokenIdentifier: v.string() },
  returns: v.boolean(),
  handler: (ctx, args) => runMutation(ctx, deleteUserBatch(args.tokenIdentifier)),
});
