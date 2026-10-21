import { Data } from "effect";

/** The caller has no auth identity. */
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

/** Clerk did not delete the User's sign-in after their data was deleted. */
export class ClerkDeleteFailed extends Data.TaggedError("ClerkDeleteFailed")<{ readonly cause: unknown }> {}

/** The vision model or the web search could not be reached or refused the search. */
export class SearchFailed extends Data.TaggedError("SearchFailed")<{ readonly cause: unknown }> {}

/** A product page could not be imported: unreachable (the page answered with an error), busy (Firecrawl rate limit) or failed. */
export class ImportFailed extends Data.TaggedError("ImportFailed")<{ readonly reason: "unreachable" | "busy" | "failed"; readonly cause: unknown }> {}

/** Every failure a Convex handler can report to its caller. */
export type GarmsError =
  | NotSignedIn | CanvasNotFound | ProductNotFound | ForeignRows
  | InvalidInput | FileKeyTaken | FileAlreadyAttached | ClerkDeleteFailed
  | SearchFailed | ImportFailed;

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
    case "ClerkDeleteFailed": return "Your data was deleted, but your sign-in could not be removed. Delete your account again to finish.";
    case "SearchFailed": return "Couldn't search for this listing. Try again.";
    case "ImportFailed": return {
      unreachable: "The product page could not be accessed.",
      busy: "Import service is busy. Try again shortly.",
      failed: "The page could not be imported. Please retry.",
    }[error.reason];
  }
}
