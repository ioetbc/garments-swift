import { Context, Effect, Layer } from "effect";
import type { Doc, Id } from "../_generated/dataModel";
import type { Group } from "../validators";
import { ConvexContext } from "./context";

/** Stored Groups, addressed by their client-generated key. */
export class GroupRepository extends Context.Service<GroupRepository, {
  byKey(key: string): Effect.Effect<Doc<"groups"> | null>;
  onCanvas(canvas: Id<"canvases">): Effect.Effect<Array<Doc<"groups">>>;
  /** Writes the Group over `existing`, the row `byKey` found for its key, or inserts it when null. */
  save(canvas: Id<"canvases">, group: Group, existing: Doc<"groups"> | null): Effect.Effect<void>;
  setMembers(id: Id<"groups">, members: Array<string>): Effect.Effect<void>;
  setEmptyCenter(id: Id<"groups">, center: { x: number; y: number }): Effect.Effect<void>;
  remove(id: Id<"groups">): Effect.Effect<void>;
  /** Deletes up to `limit` of the Canvas's rows, returning how many it deleted. */
  removeOnCanvas(canvas: Id<"canvases">, limit: number): Effect.Effect<number>;
}>()("garms/GroupRepository") {
  static readonly layer = Layer.effect(GroupRepository, Effect.gen(function* () {
    const { read, write } = yield* ConvexContext;
    return GroupRepository.of({
      byKey: (key) => read((ctx) => ctx.db.query("groups").withIndex("by_key", (q) => q.eq("key", key)).unique()),
      onCanvas: (canvas) => read((ctx) => ctx.db.query("groups").withIndex("by_canvas", (q) => q.eq("canvas", canvas)).collect()),
      save: (canvas, group, existing) => write(async (ctx) => {
        if (existing) await ctx.db.replace(existing._id, { canvas, ...group });
        else await ctx.db.insert("groups", { canvas, ...group });
      }),
      setMembers: (id, members) => write((ctx) => ctx.db.patch(id, { members })),
      setEmptyCenter: (id, emptyCenter) => write((ctx) => ctx.db.patch(id, { emptyCenter })),
      remove: (id) => write((ctx) => ctx.db.delete(id)),
      removeOnCanvas: (canvas, limit) => write(async (ctx) => {
        const rows = await ctx.db.query("groups").withIndex("by_canvas", (q) => q.eq("canvas", canvas)).take(limit);
        for (const row of rows) await ctx.db.delete(row._id);
        return rows.length;
      }),
    });
  }));
}
