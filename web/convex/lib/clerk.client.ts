import { Context, Effect, Layer } from "effect";
import { ClerkDeleteFailed } from "./errors";

/** Clerk's Backend API. */
export class ClerkClient extends Context.Service<ClerkClient, {
  /** Deletes the Clerk user, which also revokes their Sign in with Apple token. Already gone counts as done. */
  deleteUser(subject: string): Effect.Effect<void, ClerkDeleteFailed>;
}>()("garms/ClerkClient") {
  static readonly layer = Layer.sync(ClerkClient, () => ClerkClient.of({
    deleteUser: (subject) => Effect.tryPromise({
      try: async () => {
        const response = await fetch(`https://api.clerk.com/v1/users/${encodeURIComponent(subject)}`, {
          method: "DELETE",
          headers: { Authorization: `Bearer ${process.env.CLERK_SECRET_KEY}` },
        });
        return response.ok || response.status === 404 ? null : response.status;
      },
      catch: (cause) => new ClerkDeleteFailed({ cause }),
    }).pipe(Effect.flatMap((status) => status === null ? Effect.void : Effect.fail(new ClerkDeleteFailed({ cause: status })))),
  }));
}
