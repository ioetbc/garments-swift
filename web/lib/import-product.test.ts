import { describe, test } from "node:test";
import { strict as assert } from "node:assert";
import { createImportHandler, normalizeImport, publicURL } from "./import-product";

const request = (url: string) => new Request("https://garms.test/api/import", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url }) });
describe("shared product imports", () => {
  test("preserves submitted variants and fragments, prefers Open Graph", async () => {
    const url = "https://shop.example/product?size=L#blue";
    const handler = createImportHandler(async () => ({ metadata: { ogTitle: " Product ", title: "Page", ogImage: "https://cdn.example/photo.png" } }));
    const response = await handler(request(url));
    assert.deepEqual(await response.json(), { url, title: "Product", imageURL: "https://cdn.example/photo.png" });
    assert.equal(response.headers.get("cache-control"), "no-store");
  });
  test("partial metadata never chooses unrelated page images", () => {
    assert.deepEqual(normalizeImport("https://shop.example", { metadata: { title: "Page", ogImage: "/relative.jpg" }, images: ["https://cdn.example/logo.png"] }), { url: "https://shop.example", title: "Page", imageURL: null });
    assert.equal(normalizeImport("https://shop.example", {}).title, null);
  });
  test("rejects local, encoded private, credential and non-web destinations", () => {
    for (const url of ["http://localhost/a", "http://a.localhost", "http://127.1", "http://2130706433", "http://10.0.0.1", "http://172.16.0.1", "http://192.168.0.1", "http://169.254.169.254", "http://[::1]", "http://[::ffff:127.0.0.1]", "http://[fc00::1]", "file:///tmp/a", "https://a:b@shop.example"]) assert.throws(() => publicURL(url));
    assert.equal(publicURL("https://shop.example/p?a=1#x").hash, "#x");
  });
  test("handles provider failure and oversized body", async () => {
    let calls = 0;
    const handler = createImportHandler(async () => { calls++; throw new Error("secret"); });
    assert.equal((await handler(request("https://shop.example"))).status, 502);
    assert.equal((await handler(request("http://localhost"))).status, 400);
    assert.equal((await handler(request("https://shop.example/" + "a".repeat(9000)))).status, 413);
    assert.equal(calls, 1);
  });
});
