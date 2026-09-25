import { strict as assert } from "node:assert";
import { test } from "node:test";
import { extractPageContent } from "./product-availability";
import { POST } from "../app/api/product-availability/route";

test("preserves stock metadata and JSON-LD while discarding executable scripts", () => {
  const content = extractPageContent(`<html><head>
    <meta property="product:availability" content="out of stock">
    <script type="application/ld+json">{"offers":{"availability":"https://schema.org/SoldOut"}}</script>
    <script>secretTrackingCode()</script><style>.secret { color: red }</style>
    </head><body><h1>Blue jacket</h1><button disabled>Sold out</button></body></html>`);
  assert.match(content, /Blue jacket/);
  assert.match(content, /product:availability: out of stock/);
  assert.match(content, /schema.org\/SoldOut/);
  assert.match(content, /Sold out: disabled/);
  assert.doesNotMatch(content, /secretTrackingCode|color: red/);
});

function request(body: unknown) {
  return new Request("http://localhost/api/product-availability", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
}

test("rejects invalid inputs before any model call", async () => {
  for (const body of [null, {}, { html: 2 }, { html: " " }, { html: "Jacket", url: "file:///tmp/item" }]) {
    assert.equal((await POST(request(body))).status, 400);
  }
  const malformed = new Request("http://localhost", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{" });
  assert.equal((await POST(malformed)).status, 400);
  assert.equal((await POST(new Request("http://localhost", { method: "POST", body: "hello" }))).status, 415);
});

test("rejects empty shells and oversized content instead of silently truncating evidence", async () => {
  assert.equal((await POST(request({ html: "<script>renderProduct()</script>" }))).status, 422);
  assert.equal((await POST(request({ html: "x".repeat(24_001) }))).status, 413);
  assert.equal((await POST(request({ html: "x".repeat(1_000_001) }))).status, 413);
});
