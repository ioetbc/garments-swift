import { v } from "convex/values";

/** Centre and zoom a Canvas was last viewed at. */
export const viewport = v.object({ x: v.number(), y: v.number(), zoom: v.number() });

/** Amount in integer minor units with an ISO 4217 currency. */
export const price = v.object({ amount: v.number(), currency: v.string() });

/** Whether a Product can still be bought, as last checked. */
export const availability = v.object({
  state: v.union(
    v.literal("available"), v.literal("sold"), v.literal("removed"),
    v.literal("out_of_stock"), v.literal("unknown"),
  ),
  checkedAt: v.number(),
});

const point = v.object({ x: v.number(), y: v.number() });
const colour = v.object({ red: v.number(), green: v.number(), blue: v.number() });

/** A Product as the client sends and receives it. Image fields hold file keys. */
export const product = v.object({
  key: v.string(),
  title: v.string(),
  sourceUrl: v.string(),
  category: v.optional(v.string()),
  notes: v.optional(v.string()),
  price: v.optional(price),
  cutout: v.string(),
  aspect: v.number(),
  original: v.optional(v.string()),
  photos: v.array(v.string()),
  availability: v.optional(availability),
});

/** One appearance of a Product on a Canvas; `z` is a fractional stacking key. */
export const sticker = v.object({
  key: v.string(),
  product: v.string(),
  x: v.number(),
  y: v.number(),
  width: v.number(),
  height: v.number(),
  z: v.string(),
});

/** A Group of Stickers, by Sticker key, in order. */
export const group = v.object({
  key: v.string(),
  members: v.array(v.string()),
  name: v.string(),
  colour: v.optional(colour),
  notes: v.optional(v.string()),
  isRecentUploads: v.boolean(),
  emptyCenter: v.optional(point),
});

/** A pair of Stickers that must not re-join by proximity. */
export const link = v.object({ first: v.string(), second: v.string() });

/** Row-level upserts and deletes from one committed edit. */
export const changeSet = v.object({
  products: v.array(product),
  deletedProducts: v.array(v.string()),
  stickers: v.array(sticker),
  deletedStickers: v.array(v.string()),
  groups: v.array(group),
  deletedGroups: v.array(v.string()),
  links: v.array(link),
  deletedLinks: v.array(link),
});
