import { Context, Effect, Layer } from "effect";
import type { Doc, Id } from "../_generated/dataModel";
import { ConvexContext } from "./context";

/** Stored files: a client key naming an uploaded blob, and the blob itself. */
export class FileRepository extends Context.Service<FileRepository, {
  byKey(key: string): Effect.Effect<Doc<"files"> | null>;
  byStorage(storageId: Id<"_storage">): Effect.Effect<Doc<"files"> | null>;
  url(storageId: Id<"_storage">): Effect.Effect<string | null>;
  /** A short-lived URL the client POSTs file bytes to. */
  readonly uploadUrl: Effect.Effect<string>;
  add(owner: Id<"users">, key: string, storageId: Id<"_storage">): Effect.Effect<void>;
  /** Points the key at a new blob, deleting the one it replaces. */
  repoint(file: Doc<"files">, storageId: Id<"_storage">): Effect.Effect<void>;
  /** Deletes the key and its blob. */
  remove(file: Doc<"files">): Effect.Effect<void>;
}>()("garms/FileRepository") {
  static readonly layer = Layer.effect(FileRepository, Effect.gen(function* () {
    const { read, write } = yield* ConvexContext;
    return FileRepository.of({
      byKey: (key) => read((ctx) => ctx.db.query("files").withIndex("by_key", (q) => q.eq("key", key)).unique()),
      byStorage: (storageId) => read((ctx) => ctx.db.query("files").withIndex("by_storage", (q) => q.eq("storageId", storageId)).unique()),
      url: (storageId) => read((ctx) => ctx.storage.getUrl(storageId)),
      uploadUrl: write((ctx) => ctx.storage.generateUploadUrl()),
      add: (owner, key, storageId) => write(async (ctx) => { await ctx.db.insert("files", { owner, key, storageId }); }),
      repoint: (file, storageId) => write(async (ctx) => {
        if (file.storageId !== storageId) await ctx.storage.delete(file.storageId);
        await ctx.db.patch(file._id, { storageId });
      }),
      remove: (file) => write(async (ctx) => {
        await ctx.storage.delete(file.storageId);
        await ctx.db.delete(file._id);
      }),
    });
  }));
}
