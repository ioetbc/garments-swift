import { ConvexError, type Infer } from "convex/values";
import type { product } from "../validators";

/** Rejects values the validators cannot express: integer minor units and ISO 4217 codes. */
export function validateProduct(p: Infer<typeof product>) {
  if (p.price && (!Number.isSafeInteger(p.price.amount) || p.price.amount < 0 || !/^[A-Z]{3}$/.test(p.price.currency))) {
    throw new ConvexError("Price must be a non-negative whole number of minor units with an ISO 4217 currency.");
  }
  if (!Number.isFinite(p.aspect) || p.aspect <= 0) throw new ConvexError("Invalid aspect ratio.");
  if (p.availability && !Number.isFinite(p.availability.checkedAt)) throw new ConvexError("Invalid availability time.");
}
