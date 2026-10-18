import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";
import { group, product, sticker, viewport } from "./validators";

export default defineSchema({
  // tokenIdentifier is provider-agnostic, so Clerk drops in without schema changes.
  // `searches` counts today's Screenshot searches, for the per-User limit.
  users: defineTable({ tokenIdentifier: v.string(), searches: v.optional(v.object({ day: v.number(), count: v.number() })) })
    .index("by_token", ["tokenIdentifier"]),
  canvases: defineTable({ owner: v.id("users"), viewport }).index("by_owner", ["owner"]),
  // Rows are addressed by client-generated keys so the device can create them without a round trip.
  products: defineTable({ owner: v.id("users"), ...product.fields })
    .index("by_key", ["key"])
    .index("by_owner", ["owner"]),
  files: defineTable({ owner: v.id("users"), key: v.string(), storageId: v.id("_storage") })
    .index("by_key", ["key"])
    .index("by_owner", ["owner"])
    .index("by_storage", ["storageId"]),
  stickers: defineTable({ canvas: v.id("canvases"), ...sticker.fields })
    .index("by_key", ["key"])
    .index("by_canvas", ["canvas"])
    .index("by_product", ["product"]),
  groups: defineTable({ canvas: v.id("canvases"), ...group.fields })
    .index("by_key", ["key"])
    .index("by_canvas", ["canvas"]),
  // Group membership depends on history, so pulled-apart neighbours are remembered.
  detachedLinks: defineTable({ canvas: v.id("canvases"), first: v.string(), second: v.string() })
    .index("by_canvas", ["canvas", "first", "second"]),
});
