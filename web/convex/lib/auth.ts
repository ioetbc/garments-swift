import { Context, Effect, Layer, Option } from "effect";
import { ConvexContext } from "./context";
import { NotSignedIn } from "./errors";

/** Who is calling. */
export class Auth extends Context.Service<Auth, {
  /** The caller's token. */
  readonly token: Effect.Effect<string, NotSignedIn>;
}>()("garms/Auth") {
  /**
   * Identifies the caller from the auth identity. With no identity, a dev
   * deployment may act as the single User named by GARMS_DEV_USER; that variable
   * is never set on prod and is removed when Clerk lands.
   */
  static readonly layer = Layer.effect(Auth, Effect.gen(function* () {
    const { read } = yield* ConvexContext;
    // ponytail: plain process.env, not Effect Config. Convex's process.env is a proxy that
    // Effect's providers can't read (import.meta in fromEnv, Object.hasOwn in fromEnvRecord).
    const devUser = Option.fromNullishOr(process.env.GARMS_DEV_USER || undefined);
    return Auth.of({
      token: Effect.gen(function* () {
        const identity = yield* read((ctx) => ctx.auth.getUserIdentity());
        if (identity) return identity.tokenIdentifier;
        if (Option.isSome(devUser)) return `dev|${devUser.value}`;
        return yield* new NotSignedIn();
      }),
    });
  }));
}
