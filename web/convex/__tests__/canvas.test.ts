import { convexTest } from "convex-test";
import { describe, expect, test, vi, afterEach } from "vitest";
import { api, internal } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

const alice = { tokenIdentifier: "test|alice" };
const bob = { tokenIdentifier: "test|bob" };

afterEach(() => vi.unstubAllEnvs());

describe("first request", () => {
  test("creates exactly one Canvas with one Recent uploads Group", async () => {
    const t = convexTest(schema, modules).withIdentity(alice);
    const first = await t.mutation(api.canvases.start, {});
    const second = await t.mutation(api.canvases.start, {});
    expect(second).toBe(first);
    const canvas = await t.query(api.canvases.load, { canvas: first });
    expect(canvas.groups.map((g) => g.isRecentUploads)).toEqual([true]);
    expect(canvas.stickers).toEqual([]);
    expect(canvas.viewport).toEqual({ x: 0, y: 0, zoom: 1 });
  });
});

describe("identity", () => {
  test("with no identity, every public function rejects", async () => {
    vi.stubEnv("GARMS_DEV_USER", "will");
    const t = convexTest(schema, modules);
    const canvas = await t.withIdentity(alice).mutation(api.canvases.start, {});
    await expect(t.mutation(api.canvases.start, {})).rejects.toThrow(/Not signed in/);
    await expect(t.action(api.users.remove, {})).rejects.toThrow(/Not signed in/);
    await expect(t.query(api.canvases.load, { canvas })).rejects.toThrow(/Not signed in/);
    await expect(t.mutation(api.canvases.apply, { canvas, changes: emptyChanges() })).rejects.toThrow(/Not signed in/);
    await expect(t.mutation(api.canvases.saveViewport, { canvas, viewport: { x: 1, y: 1, zoom: 1 } })).rejects.toThrow(/Not signed in/);
    await expect(t.mutation(api.products.remove, { product: "p" })).rejects.toThrow(/Not signed in/);
    await expect(t.mutation(api.files.generateUploadUrl, {})).rejects.toThrow(/Not signed in/);
    await expect(t.mutation(api.files.attach, { key: "k", storageId: await t.run((ctx) => ctx.storage.store(new Blob(["x"]))) })).rejects.toThrow(/Not signed in/);
  });
});

describe("deleting a User", () => {
  const aliceClerk = { ...alice, subject: "user_alice" };

  /** Gives the User a Canvas with a Product, two Stickers, a Group, a detached link and two files. */
  async function populate(t: ReturnType<typeof convexTest>, who: { tokenIdentifier: string }, prefix: string) {
    const as = t.withIdentity(who);
    const canvas = await as.mutation(api.canvases.start, {});
    const { groups: [recent] } = await as.query(api.canvases.load, { canvas });
    const storage = [];
    for (const name of ["cutout", "original"]) {
      const storageId = await t.run((ctx) => ctx.storage.store(new Blob([prefix + name])));
      await as.mutation(api.files.attach, { key: `${prefix}-${name}`, storageId });
      storage.push(storageId);
    }
    await as.mutation(api.canvases.apply, { canvas, changes: { ...emptyChanges(),
      products: [{ ...product(prefix), cutout: `${prefix}-cutout`, original: `${prefix}-original` }],
      stickers: [sticker(`${prefix}-s1`, prefix), sticker(`${prefix}-s2`, prefix)],
      groups: [{ ...recent, members: [`${prefix}-s1`, `${prefix}-s2`] }],
      links: [{ first: `${prefix}-s1`, second: `${prefix}-s2` }] } });
    return { canvas, storage };
  }

  const rowCounts = (t: ReturnType<typeof convexTest>) => t.run(async (ctx) => {
    const counts: Record<string, number> = {};
    for (const table of ["users", "canvases", "products", "files", "stickers", "groups", "detachedLinks"] as const) {
      counts[table] = (await ctx.db.query(table).collect()).length;
    }
    return counts;
  });

  function stubClerk(status: number) {
    vi.stubEnv("CLERK_SECRET_KEY", "sk_test");
    const fetch = vi.fn(async () => new Response("{}", { status }));
    vi.stubGlobal("fetch", fetch);
    return fetch;
  }
  afterEach(() => vi.unstubAllGlobals());

  test("removes everything the User owns, then the Clerk user, and leaves other Users untouched", async () => {
    const t = convexTest(schema, modules);
    const a = await populate(t, aliceClerk, "a");
    const b = await populate(t, bob, "b");
    const bobBefore = await t.withIdentity(bob).query(api.canvases.load, { canvas: b.canvas });
    const fetch = stubClerk(200);

    await t.withIdentity(aliceClerk).action(api.users.remove, {});

    expect(await rowCounts(t)).toEqual({ users: 1, canvases: 1, products: 1, files: 2, stickers: 2, groups: 1, detachedLinks: 1 });
    expect(await t.run(async (ctx) => Promise.all(a.storage.map((id) => ctx.storage.get(id))))).toEqual([null, null]);
    expect(await t.withIdentity(bob).query(api.canvases.load, { canvas: b.canvas })).toEqual(bobBefore);
    expect(fetch).toHaveBeenCalledWith("https://api.clerk.com/v1/users/user_alice",
      expect.objectContaining({ method: "DELETE", headers: { Authorization: "Bearer sk_test" } }));
  });

  test("when Clerk fails, the User's data is still gone and deleting again succeeds", async () => {
    const t = convexTest(schema, modules);
    await populate(t, aliceClerk, "a");
    stubClerk(500);
    await expect(t.withIdentity(aliceClerk).action(api.users.remove, {})).rejects.toThrow();
    expect(Object.values(await rowCounts(t))).toEqual([0, 0, 0, 0, 0, 0, 0]);

    stubClerk(404);
    await t.withIdentity(aliceClerk).action(api.users.remove, {});
    // Signing in again after deletion starts from an empty Canvas.
    const canvas = await t.withIdentity(aliceClerk).mutation(api.canvases.start, {});
    const fresh = await t.withIdentity(aliceClerk).query(api.canvases.load, { canvas });
    expect([fresh.products.length, fresh.stickers.length, fresh.groups.map((g) => g.isRecentUploads)]).toEqual([0, 0, [true]]);
  });
});

describe("change sets", () => {
  test("a saved edit reappears on the next load", async () => {
    const t = convexTest(schema, modules).withIdentity(alice);
    const canvas = await t.mutation(api.canvases.start, {});
    const { groups: [recent] } = await t.query(api.canvases.load, { canvas });
    const coat = product("coat", { price: { amount: 25000, currency: "GBP" }, category: "Coat" });
    const s1 = sticker("s1", "coat"), s2 = sticker("s2", "coat", "a1");
    await t.mutation(api.canvases.apply, { canvas, changes: { ...emptyChanges(),
      products: [coat], stickers: [s1, s2],
      groups: [{ ...recent, members: ["s1", "s2"] }], links: [{ first: "s1", second: "s2" }] } });
    const loaded = await t.query(api.canvases.load, { canvas });
    expect(loaded.products).toEqual([coat]);
    expect(loaded.stickers).toEqual([s1, s2]);
    expect(loaded.groups).toEqual([{ ...recent, members: ["s1", "s2"] }]);
    expect(loaded.detachedLinks).toEqual([{ first: "s1", second: "s2" }]);
  });

  test("deleting the last Sticker keeps its Product", async () => {
    const t = convexTest(schema, modules).withIdentity(alice);
    const canvas = await t.mutation(api.canvases.start, {});
    await t.mutation(api.canvases.apply, { canvas, changes: { ...emptyChanges(), products: [product("coat")], stickers: [sticker("s1", "coat")] } });
    await t.mutation(api.canvases.apply, { canvas, changes: { ...emptyChanges(), deletedStickers: ["s1"] } });
    const loaded = await t.query(api.canvases.load, { canvas });
    expect([loaded.stickers.length, loaded.products.map((p) => p.key)]).toEqual([0, ["coat"]]);
  });

  test("a change set with any foreign id is rejected entirely", async () => {
    const t = convexTest(schema, modules);
    const aliceCanvas = await t.withIdentity(alice).mutation(api.canvases.start, {});
    const bobCanvas = await t.withIdentity(bob).mutation(api.canvases.start, {});
    await t.withIdentity(bob).mutation(api.canvases.apply, { canvas: bobCanvas, changes: { ...emptyChanges(), products: [product("bobs")], stickers: [sticker("bob-sticker", "bobs")] } });
    const before = await t.withIdentity(alice).query(api.canvases.load, { canvas: aliceCanvas });
    const attempts = [
      { products: [product("mine"), product("bobs")] },
      { products: [product("mine")], stickers: [sticker("s1", "bobs")] },
      { products: [product("mine")], stickers: [sticker("bob-sticker", "mine")] },
      { products: [product("mine")], deletedStickers: ["bob-sticker"] },
      { products: [product("mine")], deletedProducts: ["bobs"] },
      { products: [product("mine")], groups: [{ ...before.groups[0], members: ["bob-sticker"] }] },
    ];
    for (const attempt of attempts) {
      await expect(t.withIdentity(alice).mutation(api.canvases.apply, { canvas: aliceCanvas, changes: { ...emptyChanges(), ...attempt } }))
        .rejects.toThrow(/do not own/);
    }
    expect(await t.withIdentity(alice).query(api.canvases.load, { canvas: aliceCanvas })).toEqual(before);
    expect((await t.withIdentity(bob).query(api.canvases.load, { canvas: bobCanvas })).stickers.map((s) => s.key)).toEqual(["bob-sticker"]);
  });

  test("Price validators reject malformed values", async () => {
    const t = convexTest(schema, modules).withIdentity(alice);
    const canvas = await t.mutation(api.canvases.start, {});
    const malformed: Record<string, unknown>[] = [
      { price: { amount: 12.5, currency: "GBP" } },
      { price: { amount: -1, currency: "GBP" } },
      { price: { amount: 100, currency: "pounds" } },
    ];
    for (const fields of malformed) {
      await expect(t.mutation(api.canvases.apply, { canvas, changes: { ...emptyChanges(), products: [{ ...product("p"), ...fields } as never] } }))
        .rejects.toThrow();
    }
    expect((await t.query(api.canvases.load, { canvas })).products).toEqual([]);
  });

  test("a Product Awaiting match keeps its Candidate match across save and reload", async () => {
    const t = convexTest(schema, modules).withIdentity(alice);
    const canvas = await t.mutation(api.canvases.start, {});
    const shot = product("shot", { sourceUrl: "", match: { status: "loadFailed",
      candidate: { url: "https://shop.example/jacket", title: "Jacket", domain: "shop.example" } } });
    await t.mutation(api.canvases.apply, { canvas, changes: { ...emptyChanges(), products: [shot] } });
    expect((await t.query(api.canvases.load, { canvas })).products).toEqual([shot]);
  });

  test("malformed match states are rejected", async () => {
    const t = convexTest(schema, modules).withIdentity(alice);
    const canvas = await t.mutation(api.canvases.start, {});
    const candidate = { url: "https://shop.example/a", domain: "shop.example" };
    const malformed: Record<string, unknown>[] = [
      { match: { status: "maybe" } },
      { match: { candidate } },
      { match: { status: "found", candidate: { url: "https://shop.example/a" } } },
      { match: { status: "found", candidates: [candidate] } },
    ];
    for (const fields of malformed) {
      await expect(t.mutation(api.canvases.apply, { canvas, changes: { ...emptyChanges(), products: [{ ...product("p"), ...fields } as never] } }))
        .rejects.toThrow();
    }
    expect((await t.query(api.canvases.load, { canvas })).products).toEqual([]);
  });
});

describe("isolation", () => {
  test("a User cannot read or change another User's Canvas", async () => {
    const t = convexTest(schema, modules);
    const bobCanvas = await t.withIdentity(bob).mutation(api.canvases.start, {});
    const asAlice = t.withIdentity(alice);
    await asAlice.mutation(api.canvases.start, {});
    await expect(asAlice.query(api.canvases.load, { canvas: bobCanvas })).rejects.toThrow(/not found/);
    await expect(asAlice.mutation(api.canvases.apply, { canvas: bobCanvas, changes: emptyChanges() })).rejects.toThrow(/not found/);
    await expect(asAlice.mutation(api.canvases.saveViewport, { canvas: bobCanvas, viewport: { x: 9, y: 9, zoom: 2 } })).rejects.toThrow(/not found/);
    expect((await t.withIdentity(bob).query(api.canvases.load, { canvas: bobCanvas })).viewport).toEqual({ x: 0, y: 0, zoom: 1 });
  });

  test("a User cannot delete another User's Product", async () => {
    const t = convexTest(schema, modules);
    const bobCanvas = await t.withIdentity(bob).mutation(api.canvases.start, {});
    await t.withIdentity(bob).mutation(api.canvases.apply, { canvas: bobCanvas, changes: { ...emptyChanges(), products: [product("bobs")] } });
    await expect(t.withIdentity(alice).mutation(api.products.remove, { product: "bobs" })).rejects.toThrow(/not found/);
    expect((await t.withIdentity(bob).query(api.canvases.load, { canvas: bobCanvas })).products).toHaveLength(1);
  });

  test("a User's load never includes another User's files", async () => {
    const t = convexTest(schema, modules);
    const aliceCanvas = await t.withIdentity(alice).mutation(api.canvases.start, {});
    const bobCanvas = await t.withIdentity(bob).mutation(api.canvases.start, {});
    const storageId = await t.run((ctx) => ctx.storage.store(new Blob(["bob"])));
    await t.withIdentity(bob).mutation(api.files.attach, { key: "bob-cutout", storageId });
    await t.withIdentity(alice).mutation(api.canvases.apply, { canvas: aliceCanvas, changes: { ...emptyChanges(), products: [{ ...product("p"), cutout: "bob-cutout" }] } });
    expect((await t.withIdentity(alice).query(api.canvases.load, { canvas: aliceCanvas })).files).toEqual({});
    await expect(t.withIdentity(alice).mutation(api.files.attach, { key: "bob-cutout", storageId })).rejects.toThrow(/taken/);
    expect(Object.keys((await t.withIdentity(bob).query(api.canvases.load, { canvas: bobCanvas })).files)).toEqual([]);
  });
});

describe("deleting a Product", () => {
  test("removes its Stickers, their Group memberships and its files", async () => {
    const t = convexTest(schema, modules).withIdentity(alice);
    const canvas = await t.mutation(api.canvases.start, {});
    const { groups: [recent] } = await t.query(api.canvases.load, { canvas });
    const cutout = await t.run((ctx) => ctx.storage.store(new Blob(["cutout"])));
    const original = await t.run((ctx) => ctx.storage.store(new Blob(["original"])));
    await t.mutation(api.files.attach, { key: "coat-cutout", storageId: cutout });
    await t.mutation(api.files.attach, { key: "coat-original", storageId: original });
    await t.mutation(api.canvases.apply, { canvas, changes: { ...emptyChanges(),
      products: [{ ...product("coat"), cutout: "coat-cutout", original: "coat-original" }, product("shoe")],
      stickers: [sticker("s1", "coat"), sticker("s2", "coat"), sticker("s3", "shoe")],
      groups: [{ ...recent, members: ["s1", "s3", "s2"] }], links: [{ first: "s1", second: "s3" }] } });
    expect(Object.keys((await t.query(api.canvases.load, { canvas })).files).sort()).toEqual(["coat-cutout", "coat-original"]);

    await t.mutation(api.products.remove, { product: "coat" });

    const loaded = await t.query(api.canvases.load, { canvas });
    expect(loaded.products.map((p) => p.key)).toEqual(["shoe"]);
    expect(loaded.stickers.map((s) => s.key)).toEqual(["s3"]);
    expect(loaded.groups[0].members).toEqual(["s3"]);
    expect(loaded.detachedLinks).toEqual([]);
    expect(await t.run(async (ctx) => [await ctx.storage.get(cutout), await ctx.storage.get(original)])).toEqual([null, null]);
  });
});

describe("viewport", () => {
  test("is saved for the next load", async () => {
    const t = convexTest(schema, modules).withIdentity(alice);
    const canvas = await t.mutation(api.canvases.start, {});
    await t.mutation(api.canvases.saveViewport, { canvas, viewport: { x: 120, y: -40, zoom: 0.5 } });
    expect((await t.query(api.canvases.load, { canvas })).viewport).toEqual({ x: 120, y: -40, zoom: 0.5 });
  });
});

function product(key: string, fields: Record<string, unknown> = {}) {
  return { key, title: `Product ${key}`, sourceUrl: "https://shop.example/" + key, cutout: key + "-cutout", aspect: 0.5, photos: [], ...fields };
}

function sticker(key: string, product: string, z = "a0") {
  return { key, product, x: 10, y: 20, width: 75, height: 150, z };
}

function emptyChanges() {
  return { products: [], deletedProducts: [], stickers: [], deletedStickers: [], groups: [], deletedGroups: [], links: [], deletedLinks: [] };
}

describe("seed", () => {
  test("populates only the target account", async () => {
    const t = convexTest(schema, modules);
    const bobCanvas = await t.withIdentity(bob).mutation(api.canvases.start, {});
    const storageId = await t.run((ctx) => ctx.storage.store(new Blob(["png"])));
    const samples = [0.5, 1.6, 0.4].map((aspect, i) => ({ title: `Sample ${i}`, category: "Coat", aspect, sourceUrl: "https://shop.example", storageId }));
    await t.mutation(internal.seed.run, { tokenIdentifier: alice.tokenIdentifier, samples, count: 20 });

    const aliceCanvas = await t.withIdentity(alice).mutation(api.canvases.start, {});
    const seeded = await t.withIdentity(alice).query(api.canvases.load, { canvas: aliceCanvas });
    expect([seeded.products.length, seeded.stickers.length]).toEqual([3, 20]);
    expect(seeded.groups.filter((g) => !g.isRecentUploads).flatMap((g) => g.members).sort()).toEqual(seeded.stickers.map((s) => s.key).sort());
    const untouched = await t.withIdentity(bob).query(api.canvases.load, { canvas: bobCanvas });
    expect([untouched.products.length, untouched.stickers.length, untouched.groups.length]).toEqual([0, 0, 1]);
  });
});
