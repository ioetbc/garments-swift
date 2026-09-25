import { strict as assert } from "node:assert";
import { test } from "node:test";
import { SdkError } from "firecrawl";
import { createScrapeHandler as createCachedHandler } from "./scrape";
import { MODEL, MAX_CONTENT_LENGTH } from "./product-availability";

const createHandler = (...args: [Parameters<typeof createCachedHandler>[0], Parameters<typeof createCachedHandler>[1]]) =>
  createCachedHandler(...args, null);

// All model calls are injected: these tests never consume paid API credits.
const createScrapeHandler = (scrape: Parameters<typeof createHandler>[0]) =>
  createHandler(scrape, async () => ({ type: "choice" as const, choice: "removed" as const }));

function request(body: unknown) {
  return new Request("http://localhost/api/scrape", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
}

test("validates input without contacting Firecrawl", async () => {
  const handler = createScrapeHandler(async () => { throw new Error("Unexpected scrape"); });
  for (const body of [{}, null, { url: 12 }, { url: "file:///tmp/a" }, { url: "https://user:pass@example.com" }]) {
    assert.equal((await handler(request(body))).status, 400);
  }
  assert.equal((await handler(request({ url: "x".repeat(9000) }))).status, 413);
});

test("returns Markdown and target status with fresh server-authenticated scraping", async () => {
  const previous = process.env.FIRECRAWL_API_KEY;
  process.env.FIRECRAWL_API_KEY = "test-key";
  try {
    let calls = 0;
    const handler = createScrapeHandler(async (url, apiKey) => {
      calls++;
      assert.equal(url, "https://example.com/item");
      assert.equal(apiKey, "test-key");
      return { markdown: "# Removed", metadata: { title: "Item", statusCode: 404 } };
    });
    const response = await handler(request({ url: "https://example.com/item#details" }));
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.ok(Number.isFinite(Date.parse(body.updatedAt)));
    const { updatedAt, ...result } = body;
    void updatedAt;
    assert.deepEqual(result, { url: "https://example.com/item", markdown: "# Removed", title: "Item", statusCode: 404, classification: { status: "removed", error: null, model: MODEL } });
    assert.equal(calls, 1);
    for (const [upstream, expected] of [[401, 503], [402, 503], [429, 429], [500, 502], [408, 504]]) {
      const failing = createScrapeHandler(async () => { throw new SdkError("private error", upstream); });
      const failure = await failing(request({ url: "https://example.com" }));
      assert.equal(failure.status, expected);
      assert.doesNotMatch(await failure.text(), /private error|test-key/);
    }
    const empty = createScrapeHandler(async () => ({ markdown: " " }));
    assert.equal((await empty(request({ url: "https://example.com" }))).status, 422);
    const timeout = createScrapeHandler(async () => { throw new SdkError("timeout of 50000ms exceeded"); });
    assert.equal((await timeout(request({ url: "https://example.com" }))).status, 504);
    delete process.env.FIRECRAWL_API_KEY;
    const anonymous = createScrapeHandler(async (url, apiKey) => {
      assert.equal(apiKey, undefined);
      return { markdown: "# Anonymous scrape", metadata: { statusCode: 200 } };
    });
    assert.equal((await anonymous(request({ url: "https://example.com" }))).status, 200);
  } finally {
    if (previous === undefined) delete process.env.FIRECRAWL_API_KEY;
    else process.env.FIRECRAWL_API_KEY = previous;
  }
});


test("passes Markdown, URL and source status directly to Jev and returns every usable class", async () => {
  for (const choice of ["sold", "out_of_stock", "listing_ended", "removed", "available"] as const) {
    const handler = createHandler(
      async () => ({ markdown: "# Jacket\nSold", metadata: { statusCode: 200 } }),
      async (content, url, code) => {
        assert.equal(content, "# Jacket\nSold");
        assert.equal(url, "https://example.com/item");
        assert.equal(code, 200);
        return { type: "choice" as const, choice };
      },
    );
    const response = await handler(request({ url: "https://example.com/item" }));
    assert.equal(response.status, 200);
    assert.deepEqual((await response.json()).classification, { status: choice, error: null, model: MODEL });
  }
});

test("keeps Markdown when classification fails or the page is unreadable", async () => {
  for (const classify of [
    async () => { throw new Error("private provider details"); },
    async () => ({ type: "choice" as const, choice: "unreadable" as const }),
  ]) {
    const response = await createHandler(async () => ({ markdown: "# Page" }), classify)(request({ url: "https://example.com/item" }));
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.markdown, "# Page");
    assert.equal(body.classification.status, "unknown");
    assert.ok(body.classification.error);
    assert.doesNotMatch(JSON.stringify(body), /private provider details/);
  }
});

test("skips inference for blocked/error pages and oversized Markdown", async () => {
  for (const page of [
    ...[401, 403, 429, 500].map(statusCode => ({ markdown: "# Access denied", metadata: { statusCode } })),
    { markdown: "x".repeat(MAX_CONTENT_LENGTH + 1) },
  ]) {
    let called = false;
    const response = await createHandler(async () => page, async () => {
      called = true;
      return { type: "choice" as const, choice: "available" as const };
    })(request({ url: "https://example.com/item" }));
    assert.equal((await response.json()).classification.status, "unknown");
    assert.equal(called, false);
  }
});

test("does not report a missing resource as active even if the model does", async () => {
  for (const statusCode of [404, 410]) {
    const response = await createHandler(
      async () => ({ markdown: "# Similar items", metadata: { statusCode } }),
      async () => ({ type: "choice" as const, choice: "available" as const }),
    )(request({ url: "https://example.com/item" }));
    assert.equal((await response.json()).classification.status, "unknown");
  }
});
