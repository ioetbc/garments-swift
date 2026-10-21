import type { DocumentByName, WithoutSystemFields } from "convex/server";
import { Context, Data, Effect, Layer } from "effect";
import type { DataModel, Doc, Id, TableNames } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import type { Link } from "../validators";

/** Tables whose rows the client addresses by a generated `key`. */
export type Keyed = "products" | "files" | "stickers" | "groups";
/** Tables whose rows belong to one Canvas. */
export type OnCanvas = "stickers" | "groups" | "detachedLinks";
/** Tables whose rows belong to one User. */
export type Owned = "canvases" | "products" | "files";

/** A row of the table without its system fields. */
type Fields<T extends TableNames> = WithoutSystemFields<DocumentByName<DataModel, T>>;

/** A write while serving a query. A bug, so a defect rather than a failure. */
export class WriteInQuery extends Data.TaggedError("WriteInQuery") {}

/** The running handler's database and file storage. Convex failures are defects. */
export class Db extends Context.Service<Db, {
  get<T extends TableNames>(id: Id<T>): Effect.Effect<Doc<T> | null>;
  byKey<T extends Keyed>(table: T, key: string): Effect.Effect<Doc<T> | null>;
  /** Every row of the table on the Canvas. */
  onCanvas<T extends OnCanvas>(table: T, canvas: Id<"canvases">): Effect.Effect<Array<Doc<T>>>;
  /** Every row of the table the User owns. */
  ofOwner<T extends Owned>(table: T, owner: Id<"users">): Effect.Effect<Array<Doc<T>>>;
  /** The User signed in with this token, if they have made a request before. */
  userByToken(token: string): Effect.Effect<Doc<"users"> | null>;
  fileByStorage(storageId: Id<"_storage">): Effect.Effect<Doc<"files"> | null>;
  /** Every Sticker of a Product, across Canvases. */
  stickersOf(product: string): Effect.Effect<Array<Doc<"stickers">>>;
  link(canvas: Id<"canvases">, link: Link): Effect.Effect<Doc<"detachedLinks"> | null>;
  fileUrl(storageId: Id<"_storage">): Effect.Effect<string | null>;
  /** A short-lived URL the client POSTs file bytes to. */
  readonly uploadUrl: Effect.Effect<string>;

  insert<T extends TableNames>(table: T, value: Fields<T>): Effect.Effect<Id<T>>;
  /** Writes `value` over `existing`, or inserts it when null. */
  upsert<T extends TableNames>(table: T, existing: Doc<T> | null, value: Fields<T>): Effect.Effect<void>;
  patch<T extends TableNames>(id: Id<T>, fields: Partial<Fields<T>>): Effect.Effect<void>;
  /** Deletes a row, and the stored blob when the row is a file. */
  remove(row: Doc<TableNames>): Effect.Effect<void>;
  /** Deletes up to `limit` of the Canvas's rows, returning how many it deleted. */
  removeOnCanvas(table: OnCanvas, canvas: Id<"canvases">, limit: number): Effect.Effect<number>;
  /** Deletes up to `limit` of the User's rows (and their blobs), returning how many it deleted. */
  removeOfOwner(table: Owned, owner: Id<"users">, limit: number): Effect.Effect<number>;
}>()("garms/Db") {
  /** For query handlers: writes die with WriteInQuery. */
  static query = (ctx: QueryCtx) => Layer.succeed(Db, make(ctx, null));
  /** For mutation handlers: reads and writes. */
  static mutation = (ctx: MutationCtx) => Layer.succeed(Db, make(ctx, ctx));
}

function make(ctx: QueryCtx, writer: MutationCtx | null) {
  const read = <A>(f: () => Promise<A>) => Effect.promise(f);
  const write = <A>(f: (w: MutationCtx) => Promise<A>) => writer ? Effect.promise(() => f(writer)) : Effect.die(new WriteInQuery());
  const removeRow = async (w: MutationCtx, row: Doc<TableNames>) => {
    if ("storageId" in row) await w.storage.delete(row.storageId);
    await w.db.delete(row._id);
  };
  const removeAll = async (w: MutationCtx, rows: Array<Doc<TableNames>>) => {
    for (const row of rows) await removeRow(w, row);
    return rows.length;
  };

  // ponytail: each table union shares the index it's queried by; TypeScript can't follow an index through a
  // generic table name, so these queries name one member of the union and cast the result back. Likewise
  // replace and patch can't resolve their value type for a generic table; the interface above keeps callers typed.
  const cast = <A>(rows: Promise<unknown>) => rows as Promise<A>;

  return Db.of({
    get: (id) => read(() => ctx.db.get(id)),
    byKey: <T extends Keyed>(table: T, key: string) =>
      read(() => cast<Doc<T> | null>(ctx.db.query(table as "stickers").withIndex("by_key", (q) => q.eq("key", key)).unique())),
    onCanvas: <T extends OnCanvas>(table: T, canvas: Id<"canvases">) =>
      read(() => cast<Array<Doc<T>>>(ctx.db.query(table as "stickers").withIndex("by_canvas", (q) => q.eq("canvas", canvas)).collect())),
    ofOwner: <T extends Owned>(table: T, owner: Id<"users">) =>
      read(() => cast<Array<Doc<T>>>(ctx.db.query(table as "products").withIndex("by_owner", (q) => q.eq("owner", owner)).collect())),
    userByToken: (token) => read(() => ctx.db.query("users").withIndex("by_token", (q) => q.eq("tokenIdentifier", token)).unique()),
    fileByStorage: (storageId) => read(() => ctx.db.query("files").withIndex("by_storage", (q) => q.eq("storageId", storageId)).unique()),
    stickersOf: (product) => read(() => ctx.db.query("stickers").withIndex("by_product", (q) => q.eq("product", product)).collect()),
    link: (canvas, link) => read(() => ctx.db.query("detachedLinks")
      .withIndex("by_canvas", (q) => q.eq("canvas", canvas).eq("first", link.first).eq("second", link.second))
      .unique()),
    fileUrl: (storageId) => read(() => ctx.storage.getUrl(storageId)),
    uploadUrl: write((w) => w.storage.generateUploadUrl()),

    insert: (table, value) => write((w) => w.db.insert(table, value)),
    upsert: (table, existing, value) => write(async (w) => {
      if (existing) await w.db.replace(existing._id, value as never);
      else await w.db.insert(table, value);
    }),
    patch: (id, fields) => write((w) => w.db.patch(id, fields as never)),
    remove: (row) => write((w) => removeRow(w, row)),
    removeOnCanvas: (table, canvas, limit) => write(async (w) =>
      removeAll(w, await w.db.query(table as "stickers").withIndex("by_canvas", (q) => q.eq("canvas", canvas)).take(limit))),
    removeOfOwner: (table, owner, limit) => write(async (w) =>
      removeAll(w, await w.db.query(table as "products").withIndex("by_owner", (q) => q.eq("owner", owner)).take(limit))),
  });
}
