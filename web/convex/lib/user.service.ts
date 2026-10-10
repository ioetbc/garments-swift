import { Context, Effect, Layer } from "effect";
import type { Doc, Id } from "../_generated/dataModel";
import { Auth } from "./auth";
import { CanvasRepository } from "./canvas.repository";
import { NotSignedIn } from "./errors";
import { GroupRepository } from "./group.repository";
import { UserRepository } from "./user.repository";

/** A User and their Canvas. */
export type Owner = { readonly user: Id<"users">; readonly canvas: Id<"canvases"> };

/** Who the caller is, and creating Users on their first request. */
export class UserService extends Context.Service<UserService, {
  /** The calling User, or null before their first request created them. */
  readonly caller: Effect.Effect<Doc<"users"> | null, NotSignedIn>;
  /** The calling User and their Canvas, created on first request. */
  readonly ensureCaller: Effect.Effect<Owner, NotSignedIn>;
  /** The User for this token, created with one Canvas and its Recent uploads Group on first request. */
  ensure(token: string): Effect.Effect<Owner>;
}>()("garms/UserService") {
  static readonly layer = Layer.effect(UserService, Effect.gen(function* () {
    const auth = yield* Auth;
    const users = yield* UserRepository;
    const canvases = yield* CanvasRepository;
    const groups = yield* GroupRepository;

    const ensure = Effect.fn("UserService.ensure")(function* (token: string) {
      const existing = yield* users.byToken(token);
      if (existing) {
        const canvas = yield* canvases.firstOf(existing._id);
        if (canvas) return { user: existing._id, canvas: canvas._id };
      }
      const user = existing?._id ?? (yield* users.create(token));
      const canvas = yield* canvases.create(user, { x: 0, y: 0, zoom: 1 });
      yield* groups.save(canvas, {
        key: crypto.randomUUID(), members: [], name: "Recent uploads",
        colour: { red: 0.22, green: 1, blue: 0.08 }, isRecentUploads: true, emptyCenter: { x: 0, y: 0 },
      }, null);
      return { user, canvas };
    });

    return UserService.of({
      caller: Effect.flatMap(auth.token, (token) => users.byToken(token)),
      ensureCaller: Effect.flatMap(auth.token, ensure),
      ensure,
    });
  }));
}
