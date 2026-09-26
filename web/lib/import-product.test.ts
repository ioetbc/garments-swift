import { describe, test } from "node:test";
import { strict as assert } from "node:assert";
import { createImportHandler, normalizeImport, publicURL } from "./import-product";

const request = (url: string) => new Request("https://garms.test/api/import", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url }) });
describe("shared product imports", () => {
  test("preserves submitted variants and fragments, prefers Open Graph", async () => {
    const url = "https://shop.example/product?size=L#blue";
    const handler = createImportHandler(async () => ({ metadata: { ogTitle: " Product ", title: "Page", ogImage: "https://cdn.example/photo.png" } }));
    const response = await handler(request(url));
    const { diagnostics, ...product } = await response.json();
    assert.deepEqual(product, { url, title: "Product", imageURL: "https://cdn.example/photo.png", imageURLs: ["https://cdn.example/photo.png"] });
    assert.ok(diagnostics.some((line: string) => line.includes("Firecrawl completed")));
    assert.ok(diagnostics.some((line: string) => line.includes("no markdown")));
    assert.equal(response.headers.get("cache-control"), "no-store");
  });
  test("partial metadata never chooses unrelated page images", () => {
    assert.deepEqual(normalizeImport("https://shop.example", { metadata: { title: "Page", ogImage: "/relative.jpg" }, images: ["https://cdn.example/logo.png"] }), { url: "https://shop.example", title: "Page", imageURL: null, imageURLs: [] });
    assert.equal(normalizeImport("https://shop.example", {}).title, null);
  });
  test("falls back to alternate social metadata when ogImage is missing or invalid", () => {
    for (const key of ["og:image", "og:image:secure_url", "og:image:url", "twitter:image", "twitter:image:src"]) {
      assert.equal(normalizeImport("https://shop.example", { metadata: { ogImage: "http://cdn.example/insecure.jpg", [key]: ["/relative.jpg", "https://cdn.example/product.jpg"] } }).imageURL, "https://cdn.example/product.jpg");
    }
  });
  test("extracts HTML social images, decodes entities and preserves signed query strings", () => {
    const rawHtml = '<meta property="og:image" content="https://cdn.example/product.jpg?w=800&amp;signature=abc"><meta name="twitter:image" content="https://cdn.example/twitter.jpg">';
    assert.equal(normalizeImport("https://shop.example", { rawHtml }).imageURL, "https://cdn.example/product.jpg?w=800&signature=abc");
    assert.equal(normalizeImport("https://shop.example", { rawHtml, metadata: { ogImage: "https://cdn.example/preferred.jpg" } }).imageURL, "https://cdn.example/preferred.jpg");
    assert.equal(normalizeImport("https://shop.example", { rawHtml: '<meta name="twitter:image" content="https://cdn.example/twitter.jpg">' }).imageURL, "https://cdn.example/twitter.jpg");
  });
  test("Vinted gallery fallback selects the main listing photo and reports its source", async () => {
    const rawHtml = '<img src="https://cdn.example/logo.png"><img data-testid="item-photo-1--img" src="https://images1.vinted.net/product.webp?s=signed"><img src="https://cdn.example/recommendation.jpg">';
    const handler = createImportHandler(async () => ({ metadata: { title: "Jacket" }, rawHtml }));
    const response = await handler(request("https://www.vinted.co.uk/items/10140550570-jacket?homepage_session_id=test"));
    const body = await response.json();
    assert.equal(body.imageURL, "https://images1.vinted.net/product.webp?s=signed");
    assert.ok(body.diagnostics.some((line: string) => line.includes("Vinted listing gallery")));
    for (const url of ["https://shop.example/items/123", "https://www.vinted.co.uk/member/123", "https://www.vinted.co.uk.evil.example/items/123"]) {
      assert.equal(normalizeImport(url, { rawHtml }).imageURL, null);
    }
    assert.equal(normalizeImport("https://www.vinted.co.uk/items/123", { rawHtml: '<img src="https://cdn.example/avatar.jpg">' }).imageURL, null);
  });
  test("all fallback image sources reject unsafe URLs", () => {
    for (const image of ["http://cdn.example/a.jpg", "https://127.0.0.1/a", "https://[::1]/a", "https://a.local/a", "https://user:pass@cdn.example/a", "data:image/png;base64,AA", "/relative.jpg"]) {
      assert.equal(normalizeImport("https://www.vinted.co.uk/items/123", {
        metadata: { "twitter:image": image },
        rawHtml: `<meta property="og:image" content="${image}"><img data-testid="item-photo-1--img" src="${image}">`,
      }).imageURL, null);
    }
  });
  test("rejects local, encoded private, credential and non-web destinations", () => {
    for (const url of ["http://localhost/a", "http://a.localhost", "http://127.1", "http://2130706433", "http://10.0.0.1", "http://172.16.0.1", "http://192.168.0.1", "http://169.254.169.254", "http://[::1]", "http://[::ffff:127.0.0.1]", "http://[fc00::1]", "file:///tmp/a", "https://a:b@shop.example"]) assert.throws(() => publicURL(url));
    assert.equal(publicURL("https://shop.example/p?a=1#x").hash, "#x");
  });
  test("handles provider failure and oversized body", async () => {
    let calls = 0;
    const handler = createImportHandler(async () => { calls++; throw new Error("secret"); });
    const failed = await handler(request("https://shop.example"));
    assert.equal(failed.status, 502);
    assert.ok((await failed.json()).diagnostics.some((line: string) => line.includes("Firecrawl failed")));
    assert.equal((await handler(request("http://localhost"))).status, 400);
    assert.equal((await handler(request("https://shop.example/" + "a".repeat(9000)))).status, 413);
    assert.equal(calls, 1);
  });
});

test("provider diagnostics redact credentials and URLs", async () => {
  const handler = createImportHandler(async () => { throw new Error("Denied Bearer private-token for https://shop.example/?token=private fc-private-key"); });
  const response = await handler(request("https://shop.example"));
  const body = await response.text();
  assert.ok(body.includes("Denied"));
  assert.ok(!body.includes("private-token"));
  assert.ok(!body.includes("token=private"));
  assert.ok(!body.includes("fc-private-key"));
});

test("returns all matching Vinted streamed photos in order, without thumbnails or other listings", () => {
  const primary = "https://images1.vinted.net/first.webp?s=one";
  const second = "https://images1.vinted.net/second.webp?s=two";
  const third = "https://images1.vinted.net/third.webp?s=three";
  const stream = '8e:' + JSON.stringify(["$", "gallery", null, { data: {
    item_id: "123", photos: [{ url: primary, thumbnails: [{ url: "https://cdn.example/thumb.jpg" }] }, { url: second }, { url: "https://127.0.0.1/private.jpg" }, { url: third }],
    recommendation: { item_id: "456", photos: [{ url: "https://cdn.example/unrelated.jpg" }] },
  } }]) + '\n';
  const script = (value: string) => `<script>self.__next_f.push(${JSON.stringify([1, value])})</script>`;
  const rawHtml = script(stream.slice(0, 100)) + script(stream.slice(100)) + '<img data-testid="item-photo-1--img" src="' + primary + '">';
  const product = normalizeImport("https://www.vinted.co.uk/items/123-jacket?size=M", { metadata: { ogImage: primary }, rawHtml });
  assert.deepEqual(product.imageURLs, [primary, second, third]);
  assert.equal(product.imageURL, primary);
});

test("reads only matching structured Product images and tolerates malformed scripts", () => {
  const products = { "@graph": [
    { "@type": "Product", name: "Unrelated", image: "https://cdn.example/unrelated.jpg" },
    { "@type": "Product", name: "Jacket", image: ["https://cdn.example/first.jpg", { "@type": "ImageObject", contentUrl: "https://cdn.example/second.jpg" }, "https://cdn.example/first.jpg", "http://cdn.example/unsafe.jpg"] },
  ] };
  const rawHtml = '<script type="application/ld+json">invalid</script><script type="application/ld+json">' + JSON.stringify(products) + '</script>';
  const product = normalizeImport("https://shop.example/jacket", { metadata: { title: "Jacket | Shop" }, rawHtml });
  assert.deepEqual(product.imageURLs, ["https://cdn.example/first.jpg", "https://cdn.example/second.jpg"]);
  assert.equal(product.imageURL, product.imageURLs[0]);
});

test("SSENSE uses all rendered SKU photos instead of the broken JSON-LD template", async () => {
  const url = "https://www.ssense.com/en-us/men/product/julius/black-coated-big-shirt/19247841?utm_source=SSENSE";
  const photo = (index: number, transform = "f_auto,c_limit,w_1920", sku = "262420M192001") => `https://img.ssensemedia.com/images/${transform}/${sku}_${index}/julius-black-coated-big-shirt.jpg`;
  const rawHtml = `<script type="application/ld+json">${JSON.stringify({
    "@type": "Product", productID: "19247841", sku: "262420M192001", name: "Black Coated Big Shirt",
    url: url.split("?")[0], image: photo(1, "__IMAGE_PARAMS__"),
  })}</script>` + [photo(3), photo(1), photo(2), photo(4), photo(1, "w_640"), photo(1, "w_640", "OTHER")]
    .map(src => `<img loading="lazy" src="${src}">`).join("");
  const handler = createImportHandler(async () => ({ metadata: { ogImage: photo(1, "w_640") }, rawHtml }));
  const result = await (await handler(request(url))).json();
  assert.deepEqual(result.imageURLs, [1, 2, 3, 4].map(index => photo(index)));
  assert.equal(result.imageURL, photo(1));
  assert.ok(result.diagnostics.some((line: string) => line.includes("product gallery. Gallery: 4 images")));
  const fallback = normalizeImport(url, { metadata: { ogImage: photo(1, "w_640") }, rawHtml: rawHtml.replace(/<img[^>]*>/g, "") });
  assert.deepEqual(fallback.imageURLs, [photo(1, "w_640")]);
});

test("SSENSE gallery rejects unrelated SKUs, unsafe URLs and lookalike hosts", () => {
  const url = "https://www.ssense.com/en-us/men/product/julius/shirt/19247841";
  const primary = "https://img.ssensemedia.com/images/w_640/262420M192001_1/shirt.jpg";
  const rawHtml = `<script type="application/ld+json">${JSON.stringify({
    "@type": "Product", productID: "999", sku: "OTHER",
  })}</script><img src="https://img.ssensemedia.com/images/w_1920/OTHER_2/shirt.jpg">
    <img src="http://img.ssensemedia.com/images/w_1920/262420M192001_2/shirt.jpg">
    <img src="https://user:pass@img.ssensemedia.com/images/w_1920/262420M192001_2/shirt.jpg">
    <img src="https://img.ssensemedia.com.evil.example/images/w_1920/262420M192001_2/shirt.jpg">`;
  assert.deepEqual(normalizeImport(url, { metadata: { ogImage: primary }, rawHtml }).imageURLs, [primary]);
  assert.deepEqual(normalizeImport(url.replace("ssense.com", "ssense.com.evil.example"), {
    metadata: { ogImage: primary }, rawHtml: '<img src="https://img.ssensemedia.com/images/w_1920/262420M192001_2/shirt.jpg">',
  }).imageURLs, [primary]);
});
