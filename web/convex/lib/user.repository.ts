import { Context, Effect, Layer } from "effect";
import type { Doc, Id } from "../_generated/dataModel";
import { ConvexContext } from "./context";

/** Stored Users, found by their sign-in token. */
export class UserRepository extends Context.Service<UserRepository, {
  /** The User signed in with this token, if they have made a request before. */
  byToken(token: string): Effect.Effect<Doc<"users"> | null>;
  create(token: string): Effect.Effect<Id<"users">>;
  setSearches(id: Id<"users">, searches: { day: number; count: number }): Effect.Effect<void>;
  remove(id: Id<"users">): Effect.Effect<void>;
}>()("garms/UserRepository") {
  static readonly layer = Layer.effect(UserRepository, Effect.gen(function* () {
    const { read, write } = yield* ConvexContext;
    return UserRepository.of({
      byToken: (token) => read((ctx) => ctx.db.query("users").withIndex("by_token", (q) => q.eq("tokenIdentifier", token)).unique()),
      create: (tokenIdentifier) => write((ctx) => ctx.db.insert("users", { tokenIdentifier })),
      setSearches: (id, searches) => write((ctx) => ctx.db.patch(id, { searches })),
      remove: (id) => write((ctx) => ctx.db.delete(id)),
    });
  }));
}
