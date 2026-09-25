import { strict as assert } from "node:assert";
import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { CACHE_TTL_MS, createScrapeCache } from "./scrape-cache";
import { createScrapeHandler } from "./scrape";

const request = (url = "https://example.com/item") => new Request("http://localhost/api/scrape", {
  method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url }),
});

test("persists results across handlers, skips both paid APIs until exactly one day old, and separates URLs", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "scrape-cache-"));
  try {
    let now = Date.now();
    let scrapes = 0;
    let classifications = 0;
    const handler = () => createScrapeHandler(
      async () => { scrapes++; return { markdown: "# Jacket" }; },
      async () => { classifications++; return { type: "choice", choice: "sold" }; },
      createScrapeCache(directory, () => now),
    );
    const first = await (await handler()(request())).json();
    const files = await readdir(directory);
    assert.equal(files.length, 1);
    assert.deepEqual(JSON.parse(await readFile(path.join(directory, files[0]), "utf8")), first);
    now = Date.parse(first.updatedAt) + CACHE_TTL_MS - 1;
    assert.deepEqual(await (await handler()(request("https://example.com/item#details"))).json(), first);
    assert.equal(scrapes, 1);
    assert.equal(classifications, 1);
    now++;
    assert.equal((await handler()(request())).status, 200);
    assert.equal(scrapes, 2);
    assert.equal(classifications, 2);
    await handler()(request("https://example.com/other"));
    assert.equal(scrapes, 3);
    assert.equal(classifications, 3);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("corrupt files are refreshed; unknown results and upstream failures are not cached", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "scrape-cache-"));
  try {
    const cache = createScrapeCache(directory);
    const success = createScrapeHandler(async () => ({ markdown: "Jacket" }), async () => ({ type: "choice", choice: "available" }), cache);
    await success(request());
    const file = path.join(directory, (await readdir(directory))[0]);
    await writeFile(file, "{broken");
    assert.equal(await cache.get("https://example.com/item"), null);
    assert.equal((await success(request())).status, 200);
    assert.equal((await cache.get("https://example.com/item"))?.classification.status, "available");
    const unknown = createScrapeHandler(async () => ({ markdown: "Login" }), async () => ({ type: "choice", choice: "unreadable" }), cache);
    assert.equal((await unknown(request("https://example.com/unknown"))).status, 200);
    assert.equal(await cache.get("https://example.com/unknown"), null);
    const failed = createScrapeHandler(async () => { throw new Error("upstream"); }, undefined, cache);
    assert.equal((await failed(request("https://example.com/failed"))).status, 502);
    assert.equal((await readdir(directory)).length, 1);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
