import type { Auth as ConvexAuth, UserIdentity } from "convex/server";
import { Context, Effect, Layer } from "effect";
import { NotSignedIn } from "./errors";

/** Who is calling. A request with no auth identity is always rejected. */
export class Auth extends Context.Service<Auth, {
  /** The caller's auth identity. */
  readonly identity: Effect.Effect<UserIdentity, NotSignedIn>;
  /** The caller's token, which names their User. */
  readonly token: Effect.Effect<string, NotSignedIn>;
}>()("garms/Auth") {
  /** Reads the identity from any handler's context, actions included. */
  static layer = (ctx: { auth: ConvexAuth }) => {
    const identity = Effect.gen(function* () {
      const found = yield* Effect.promise(() => ctx.auth.getUserIdentity());
      if (!found) return yield* new NotSignedIn();
      return found;
    });
    return Layer.succeed(Auth, Auth.of({ identity, token: Effect.map(identity, (i) => i.tokenIdentifier) }));
  };
}
