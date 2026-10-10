import { Context, Effect, Layer } from "effect";
import type { Id } from "../_generated/dataModel";
import { FileAlreadyAttached, FileKeyTaken, NotSignedIn } from "./errors";
import { FileRepository } from "./file.repository";
import { UserService } from "./user.service";

/** Uploading files and naming them by the client's key. */
export class FileService extends Context.Service<FileService, {
  /** A short-lived URL the signed-in caller POSTs image bytes to. */
  readonly uploadUrl: Effect.Effect<string, NotSignedIn>;
  /** Names an uploaded file by the client's key, so Products can reference it before the upload finishes. */
  attach(key: string, storageId: Id<"_storage">): Effect.Effect<void, NotSignedIn | FileKeyTaken | FileAlreadyAttached>;
}>()("garms/FileService") {
  static readonly layer = Layer.effect(FileService, Effect.gen(function* () {
    const users = yield* UserService;
    const files = yield* FileRepository;

    const attach = Effect.fn("FileService.attach")(function* (key: string, storageId: Id<"_storage">) {
      const { user } = yield* users.ensureCaller;
      const existing = yield* files.byKey(key);
      if (existing && existing.owner !== user) return yield* new FileKeyTaken();
      const claimed = yield* files.byStorage(storageId);
      if (claimed && claimed.key !== key) return yield* new FileAlreadyAttached();
      if (existing) yield* files.repoint(existing, storageId);
      else yield* files.add(user, key, storageId);
    });

    return FileService.of({
      uploadUrl: Effect.andThen(users.ensureCaller, files.uploadUrl),
      attach,
    });
  })).pipe(Layer.provide(UserService.layer));
}
