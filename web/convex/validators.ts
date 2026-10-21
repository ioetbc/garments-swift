import { type Infer, v } from "convex/values";

/** Centre and zoom a Canvas was last viewed at. */
export const viewport = v.object({ x: v.number(), y: v.number(), zoom: v.number() });

/** Amount in integer minor units with an ISO 4217 currency. */
export const price = v.object({ amount: v.number(), currency: v.string() });

/** A web page that might be the listing a Screenshot shows. */
export const candidate = v.object({
  url: v.string(),
  title: v.optional(v.string()),
  domain: v.string(),
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

/** A product page's details, read by `imports:product`. Image URLs are public HTTPS, the first being the main image. */
export const importedProduct = v.object({
  url: v.string(),
  title: v.union(v.string(), v.null()),
  imageURL: v.union(v.string(), v.null()),
  imageURLs: v.array(v.string()),
  price: v.union(price, v.null()),
});

export type Viewport = Infer<typeof viewport>;
export type Product = Infer<typeof product>;
export type Sticker = Infer<typeof sticker>;
export type Group = Infer<typeof group>;
export type Link = Infer<typeof link>;
export type ChangeSet = Infer<typeof changeSet>;
export type ImportedProduct = Infer<typeof importedProduct>;
export type Candidate = Infer<typeof candidate>;
