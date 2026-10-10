import { Context, Effect, Layer } from "effect";
import { internal } from "../_generated/api";
import type { ActionCtx } from "../_generated/server";
import { Auth } from "./auth";
import { ClerkClient } from "./clerk.client";
import { ClerkDeleteFailed, NotSignedIn } from "./errors";

/** Runs one UserService.deleteBatch in its own transaction, from an action. */
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
