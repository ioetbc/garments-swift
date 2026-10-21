import { Context, Effect, Layer } from "effect";
import { internal } from "../_generated/api";
import type { ActionCtx } from "../_generated/server";
import { Auth } from "./auth";
import { ClerkClient } from "./clerk.client";
import { Db } from "./db";
import { ClerkDeleteFailed, NotSignedIn } from "./errors";

// Rows per kind per transaction, well inside Convex's per-transaction limits.
const BATCH = 200;

/**
 * Deletes up to one batch of everything the User owns, the User last.
 * Returns true once the User is gone; safe to repeat after a failure part way.
 */
export const deleteBatch = Effect.fn("deleteBatch")(function* (token: string) {
  const db = yield* Db;
  const user = yield* db.userByToken(token);
  if (!user) return true;
  for (const canvas of yield* db.ofOwner("canvases", user._id)) {
    const removed = (yield* db.removeOnCanvas("stickers", canvas._id, BATCH))
      + (yield* db.removeOnCanvas("groups", canvas._id, BATCH))
      + (yield* db.removeOnCanvas("detachedLinks", canvas._id, BATCH));
    if (removed) return false;
    yield* db.remove(canvas);
  }
  if (yield* db.removeOfOwner("products", user._id, BATCH)) return false;
  if (yield* db.removeOfOwner("files", user._id, BATCH)) return false;
  yield* db.remove(user);
  return true;
});

/** Runs one deleteBatch in its own transaction, from an action. */
export class DeletionBatches extends Context.Service<DeletionBatches, {
  /** True once the User is gone. */
  run(token: string): Effect.Effect<boolean>;
}>()("garms/DeletionBatches") {
  static layer = (ctx: ActionCtx) => Layer.succeed(DeletionBatches, DeletionBatches.of({
    run: (tokenIdentifier) => Effect.promise((): Promise<boolean> => ctx.runMutation(internal.users.deleteBatch, { tokenIdentifier })),
  }));
}

/** A User's account across Convex and Clerk. */
export class AccountService extends Context.Service<AccountService, {
  /**
   * Deletes the calling User: everything they own in Convex first, then their Clerk user.
   * Every step succeeds when there is nothing left, so a failure part way is finished by deleting again.
   */
  readonly remove: Effect.Effect<void, NotSignedIn | ClerkDeleteFailed>;
}>()("garms/AccountService") {
  static readonly layer = Layer.effect(AccountService, Effect.gen(function* () {
    const auth = yield* Auth;
    const batches = yield* DeletionBatches;
    const clerk = yield* ClerkClient;
    return AccountService.of({
      remove: Effect.gen(function* () {
        const identity = yield* auth.identity;
        while (!(yield* batches.run(identity.tokenIdentifier)));
        yield* clerk.deleteUser(identity.subject);
      }).pipe(Effect.withSpan("AccountService.remove")),
    });
  }));
}
