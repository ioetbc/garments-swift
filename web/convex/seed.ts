import { ConvexError, v } from "convex/values";
import { internalMutation } from "./_generated/server";
import { ensureUser } from "./lib/auth";

// Internal only: run from a developer machine with `npx convex run`, never reachable from the app.

/** Upload URL for one sample image. */
export const uploadUrl = internalMutation({
  args: {},
  returns: v.string(),
  handler: async (ctx) => await ctx.storage.generateUploadUrl(),
});

const EDGE = 150;
const GAP = 150;

/**
 * Seeds the named account's empty Canvas with `count` Stickers cycling through
 * the sample Products, arranged in repeatable clusters that each form a Group.
 */
export const run = internalMutation({
  args: {
    tokenIdentifier: v.string(),
    count: v.optional(v.number()),
    samples: v.array(v.object({
      title: v.string(), category: v.string(), aspect: v.number(), sourceUrl: v.string(), storageId: v.id("_storage"),
    })),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const { user, canvas } = await ensureUser(ctx, args.tokenIdentifier);
    const existing = await ctx.db.query("stickers").withIndex("by_canvas", (q) => q.eq("canvas", canvas)).first();
    if (existing) throw new ConvexError("This account's Canvas already has Stickers.");

    const products: { key: string; aspect: number }[] = [];
    for (const sample of args.samples) {
      const key = crypto.randomUUID();
      await ctx.db.insert("files", { owner: user, key: `${key}-cutout`, storageId: sample.storageId });
      await ctx.db.insert("products", {
        owner: user, key, title: sample.title, category: sample.category, sourceUrl: sample.sourceUrl,
        cutout: `${key}-cutout`, aspect: sample.aspect, photos: [], price: { amount: 25000, currency: "GBP" },
      });
      products.push({ key, aspect: sample.aspect });
    }

    const items = Array.from({ length: args.count ?? 100 }, (_, i) => {
      const product = products[i % products.length];
      const height = EDGE / Math.max(1, product.aspect);
      return { key: crypto.randomUUID(), product: product.key, width: height * product.aspect, height, x: 0, y: 0, z: String(i).padStart(4, "0") };
    });
    const clusters = layout(items);
    for (const item of items) await ctx.db.insert("stickers", { canvas, ...item });
    for (const [number, cluster] of clusters.entries()) {
      if (cluster.length < 2) continue;
      const round = Math.floor(number / PLACEHOLDER_NAMES.length);
      const name = PLACEHOLDER_NAMES[number % PLACEHOLDER_NAMES.length] + (round ? ` ${round + 1}` : "");
      await ctx.db.insert("groups", { canvas, key: crypto.randomUUID(), members: cluster.map((i) => i.key), name, isRecentUploads: false });
    }

    const bounds = union(items);
    const recent = await ctx.db.query("groups").withIndex("by_canvas", (q) => q.eq("canvas", canvas)).filter((q) => q.eq(q.field("isRecentUploads"), true)).unique();
    if (recent) await ctx.db.patch(recent._id, { emptyCenter: { x: bounds.maxX + 250, y: bounds.minY + 422 } });
    const first = union(clusters[0] ?? []);
    if (clusters.length) await ctx.db.patch(canvas, { viewport: { x: (first.minX + first.maxX) / 2, y: (first.minY + first.maxY) / 2, zoom: 1 } });
    return null;
  },
});

const PLACEHOLDER_NAMES = [
  "To buy summer", "Things to buy soon", "Etsy ending soon", "Waiting for a sale",
  "Holiday wishlist", "Everyday basics", "Winter layers", "Shoes to consider",
  "For the weekend", "Work outfit ideas", "Secondhand finds", "Saved for payday",
];

type Item = { x: number; y: number; width: number; height: number };
type Rect = { minX: number; minY: number; maxX: number; maxY: number };

function union(items: Item[]): Rect {
  return items.reduce((r, i) => ({
    minX: Math.min(r.minX, i.x - i.width / 2), minY: Math.min(r.minY, i.y - i.height / 2),
    maxX: Math.max(r.maxX, i.x + i.width / 2), maxY: Math.max(r.maxY, i.y + i.height / 2),
  }), { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity });
}

function distance(a: Rect, b: Rect) {
  return Math.hypot(Math.max(b.minX - a.maxX, a.minX - b.maxX, 0), Math.max(b.minY - a.maxY, a.minY - b.maxY, 0));
}

/** The app's former fixture layout: two-row clusters scattered with a fixed seed. Moves items in place. */
function layout<T extends Item>(items: T[]): T[][] {
  const clusters: T[][] = [];
  const sizes = [4, 3, 5, 4, 5, 3];
  for (let cursor = 0; cursor < items.length;) {
    const remaining = items.length - cursor;
    let count = remaining <= 5 ? remaining : sizes[clusters.length % sizes.length];
    // Avoid leaving a final cluster of just one or two items.
    if (remaining > count && remaining - count < 3) count = remaining - 3;
    const cluster = items.slice(cursor, cursor + count);
    const topCount = Math.ceil(count / 2);
    let x = 0;
    cluster.forEach((item, index) => {
      if (index === topCount) x = clusters.length % 2 === 0 ? 18 : 0;
      item.x = x + item.width / 2;
      item.y = index < topCount ? EDGE - item.height / 2 : EDGE + 16 + item.height / 2;
      x += item.width + 16;
    });
    clusters.push(cluster);
    cursor += count;
  }

  const bounds = clusters.map(union);
  const aspect = 334 / 788; // A phone viewport less margins.
  const area = bounds.reduce((sum, b) => sum + (b.maxX - b.minX + GAP) * (b.maxY - b.minY + GAP), 0) * 1.8;
  let fieldWidth = Math.max(Math.sqrt(area * aspect), Math.max(...bounds.map((b) => b.maxX - b.minX)) + GAP);
  let fieldHeight = Math.max(Math.sqrt(area / aspect), Math.max(...bounds.map((b) => b.maxY - b.minY)) + GAP);
  let state = 0xca4a5en;
  const random = () => {
    state = (state * 6364136223846793005n + 1442695040888963407n) & 0xffffffffffffffffn;
    return Number(state >> 11n) / 2 ** 53;
  };
  const scattered: Rect[] = [];
  for (const local of bounds) {
    const width = local.maxX - local.minX, height = local.maxY - local.minY;
    let position: Rect | undefined;
    for (let attempt = 0; attempt < 2000 && !position; attempt++) {
      if (attempt > 0 && attempt % 200 === 0) { fieldWidth *= 1.12; fieldHeight *= 1.12; }
      const minX = random() * (fieldWidth - width), minY = random() * (fieldHeight - height);
      const candidate = { minX, minY, maxX: minX + width, maxY: minY + height };
      if (scattered.every((s) => distance(s, candidate) >= GAP)) position = candidate;
    }
    const fallbackX = Math.max(0, ...scattered.map((s) => s.maxX)) + GAP, fallbackY = random() * fieldHeight;
    scattered.push(position ?? { minX: fallbackX, minY: fallbackY, maxX: fallbackX + width, maxY: fallbackY + height });
  }
  clusters.forEach((cluster, number) => {
    for (const item of cluster) {
      item.x += scattered[number].minX - bounds[number].minX;
      item.y += scattered[number].minY - bounds[number].minY;
    }
  });
  return clusters;
}
