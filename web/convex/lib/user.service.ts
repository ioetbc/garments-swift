import { Context, Effect, Layer } from "effect";
import type { Doc, Id } from "../_generated/dataModel";
import { Auth } from "./auth";
import { CanvasRepository } from "./canvas.repository";
import { NotSignedIn } from "./errors";
import { FileRepository } from "./file.repository";
import { GroupRepository } from "./group.repository";
import { LinkRepository } from "./link.repository";
import { ProductRepository } from "./product.repository";
import { StickerRepository } from "./sticker.repository";
import { UserRepository } from "./user.repository";

// Rows per kind per transaction, well inside Convex's per-transaction limits.
const BATCH = 200;
// ponytail: fixed UTC-day window; a sliding window if Users hit it at midnight.
const SEARCHES_PER_DAY = 30;
const DAY = 24 * 60 * 60 * 1000;

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
  /**
   * Deletes up to one batch of everything the User owns, the User last.
   * Returns true once the User is gone; safe to repeat after a failure part way.
   */
  deleteBatch(token: string): Effect.Effect<boolean>;
  /** Counts one Screenshot search against the User's daily limit. False once the limit is used up. */
  claimSearch(token: string): Effect.Effect<boolean>;
}>()("garms/UserService") {
  static readonly layer = Layer.effect(UserService, Effect.gen(function* () {
    const auth = yield* Auth;
    const users = yield* UserRepository;
    const canvases = yield* CanvasRepository;
    const groups = yield* GroupRepository;
    const stickers = yield* StickerRepository;
    const links = yield* LinkRepository;
    const products = yield* ProductRepository;
    const files = yield* FileRepository;

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

    const deleteBatch = Effect.fn("UserService.deleteBatch")(function* (token: string) {
      const user = yield* users.byToken(token);
      if (!user) return true;
      for (const canvas of yield* canvases.ofOwner(user._id, BATCH)) {
        const removed = (yield* stickers.removeOnCanvas(canvas._id, BATCH))
          + (yield* groups.removeOnCanvas(canvas._id, BATCH))
          + (yield* links.removeOnCanvas(canvas._id, BATCH));
        if (removed) return false;
        yield* canvases.remove(canvas._id);
      }
      if (yield* products.removeOfOwner(user._id, BATCH)) return false;
      if (yield* files.removeOfOwner(user._id, BATCH)) return false;
      yield* users.remove(user._id);
      return true;
    });

    const claimSearch = Effect.fn("UserService.claimSearch")(function* (token: string) {
      yield* ensure(token);
      const user = yield* users.byToken(token);
      if (!user) return false;
      const day = Math.floor(Date.now() / DAY);
      const count = user.searches?.day === day ? user.searches.count : 0;
      if (count >= SEARCHES_PER_DAY) return false;
      yield* users.setSearches(user._id, { day, count: count + 1 });
      return true;
    });

    return UserService.of({
      caller: Effect.flatMap(auth.token, (token) => users.byToken(token)),
      ensureCaller: Effect.flatMap(auth.token, ensure),
      ensure,
      deleteBatch,
      claimSearch,
    });
  }));
}
