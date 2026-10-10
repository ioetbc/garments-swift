import { Context, Effect, Layer } from "effect";
import type { Sample } from "../validators";
import { CanvasRepository } from "./canvas.repository";
import { CanvasNotEmpty } from "./errors";
import { FileRepository } from "./file.repository";
import { GroupRepository } from "./group.repository";
import { ProductRepository } from "./product.repository";
import { StickerRepository } from "./sticker.repository";
import { UserService } from "./user.service";

const EDGE = 150;
const GAP = 150;

/** Fills a developer account's Canvas with sample Products. Never reachable from the app. */
export class SeedService extends Context.Service<SeedService, {
  /** Upload URL for one sample image. */
  readonly uploadUrl: Effect.Effect<string>;
  /**
   * Seeds the named account's empty Canvas with `count` Stickers cycling through
   * the sample Products, arranged in repeatable clusters that each form a Group.
   */
  seed(token: string, count: number, samples: Array<Sample>): Effect.Effect<void, CanvasNotEmpty>;
}>()("garms/SeedService") {
  static readonly layer = Layer.effect(SeedService, Effect.gen(function* () {
    const users = yield* UserService;
    const canvases = yield* CanvasRepository;
    const products = yield* ProductRepository;
    const stickers = yield* StickerRepository;
    const groups = yield* GroupRepository;
    const files = yield* FileRepository;

    const seed = Effect.fn("SeedService.seed")(function* (token: string, count: number, samples: Array<Sample>) {
      const { user, canvas } = yield* users.ensure(token);
      if ((yield* stickers.onCanvas(canvas)).length) return yield* new CanvasNotEmpty();

      const seeded: { key: string; aspect: number }[] = [];
      for (const sample of samples) {
        const key = crypto.randomUUID();
        yield* files.add(user, `${key}-cutout`, sample.storageId);
        yield* products.save(user, {
          key, title: sample.title, category: sample.category, sourceUrl: sample.sourceUrl,
          cutout: `${key}-cutout`, aspect: sample.aspect, photos: [], price: { amount: 25000, currency: "GBP" },
        }, null);
        seeded.push({ key, aspect: sample.aspect });
      }

      const items = Array.from({ length: count }, (_, i) => {
        const product = seeded[i % seeded.length];
        const height = EDGE / Math.max(1, product.aspect);
        return { key: crypto.randomUUID(), product: product.key, width: height * product.aspect, height, x: 0, y: 0, z: String(i).padStart(4, "0") };
      });
      const clusters = layout(items);
      for (const item of items) yield* stickers.save(canvas, item, null);
      for (const [number, cluster] of clusters.entries()) {
        if (cluster.length < 2) continue;
        const round = Math.floor(number / PLACEHOLDER_NAMES.length);
        const name = PLACEHOLDER_NAMES[number % PLACEHOLDER_NAMES.length] + (round ? ` ${round + 1}` : "");
        yield* groups.save(canvas, { key: crypto.randomUUID(), members: cluster.map((i) => i.key), name, isRecentUploads: false }, null);
      }

      const bounds = union(items);
      const recent = (yield* groups.onCanvas(canvas)).find((g) => g.isRecentUploads);
      if (recent) yield* groups.setEmptyCenter(recent._id, { x: bounds.maxX + 250, y: bounds.minY + 422 });
      const first = union(clusters[0] ?? []);
      if (clusters.length) yield* canvases.setViewport(canvas, { x: (first.minX + first.maxX) / 2, y: (first.minY + first.maxY) / 2, zoom: 1 });
    });

    return SeedService.of({ uploadUrl: files.uploadUrl, seed });
  })).pipe(Layer.provide(UserService.layer));
}

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
