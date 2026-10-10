import { Data } from "effect";

/** The caller has no auth identity and this is not a dev deployment. */
export class NotSignedIn extends Data.TaggedError("NotSignedIn") {}

/** The Canvas does not exist or belongs to someone else; callers can't tell which. */
export class CanvasNotFound extends Data.TaggedError("CanvasNotFound") {}

/** The Product belongs to someone else. */
export class ProductNotFound extends Data.TaggedError("ProductNotFound") {}

/** A change set touches or references a row the caller does not own. */
export class ForeignRows extends Data.TaggedError("ForeignRows") {}

/** A value passed the validators but breaks a rule they cannot express. */
export class InvalidInput extends Data.TaggedError("InvalidInput")<{ readonly message: string }> {}

/** Another User has already attached a file under this key. */
export class FileKeyTaken extends Data.TaggedError("FileKeyTaken") {}

/** The uploaded file is already attached under a different key. */
export class FileAlreadyAttached extends Data.TaggedError("FileAlreadyAttached") {}

/** Seeding refuses a Canvas that already has Stickers. */
export class CanvasNotEmpty extends Data.TaggedError("CanvasNotEmpty") {}

/** Clerk did not delete the User's sign-in after their data was deleted. */
export class ClerkDeleteFailed extends Data.TaggedError("ClerkDeleteFailed")<{ readonly cause: unknown }> {}

/** Every failure a Convex handler can report to its caller. */
export type GarmsError =
  | NotSignedIn | CanvasNotFound | ProductNotFound | ForeignRows
  | InvalidInput | FileKeyTaken | FileAlreadyAttached | CanvasNotEmpty | ClerkDeleteFailed;

/** The message the client sees for each failure. */
export function messageOf(error: GarmsError): string {
  switch (error._tag) {
    case "NotSignedIn": return "Not signed in.";
    case "CanvasNotFound": return "Canvas not found.";
    case "ProductNotFound": return "Product not found.";
    case "ForeignRows": return "Change set references rows you do not own.";
    case "InvalidInput": return error.message;
    case "FileKeyTaken": return "File key is taken.";
    case "FileAlreadyAttached": return "File is already attached.";
    case "CanvasNotEmpty": return "This account's Canvas already has Stickers.";
    case "ClerkDeleteFailed": return "Your data was deleted, but your sign-in could not be removed. Delete your account again to finish.";
  }
}
