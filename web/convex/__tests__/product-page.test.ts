// @vitest-environment node
import { describe, expect, it } from "@effect/vitest";
import { Effect } from "effect";
import { SdkError, type Document } from "firecrawl";
import { extractProduct, ProductPageReader, publicURL, type Scrape } from "../lib/product-page.client";

const extract = (url: string, document: Document) => extractProduct(url, document).product;

describe("reading a product page", () => {
  const reader = (scrape: Scrape) => ProductPageReader.make(scrape);

  it.effect("preserves submitted variants and fragments, prefers Open Graph", () => Effect.gen(function* () {
    const url = "https://shop.example/product?size=L#blue";
    const product = yield* reader(async () => ({ metadata: { ogTitle: " Product ", title: "Page", ogImage: "https://cdn.example/photo.png" } })).read(` ${url} `);
    expect(product).toEqual({ url, title: "Product", imageURLs: ["https://cdn.example/photo.png"], price: null });
  }));

  it.effect("rejects a private URL without scraping", () => Effect.gen(function* () {
    let calls = 0;
    const error = yield* Effect.flip(reader(async () => { calls++; return {}; }).read("http://localhost"));
    expect([error._tag, calls]).toEqual(["InvalidInput", 0]);
  }));

  it.effect("reports an error page, a busy provider and a failed scrape", () => Effect.gen(function* () {
    const reason = (scrape: Scrape) => Effect.flip(reader(scrape).read("https://shop.example")).pipe(
      Effect.map((error) => error._tag === "ImportFailed" ? error.reason : error._tag));
    expect(yield* reason(async () => ({ metadata: { statusCode: 404 } }))).toBe("unreachable");
    expect(yield* reason(async () => { throw new SdkError("Rate limited", 429); })).toBe("busy");
    expect(yield* reason(async () => { throw new Error("secret"); })).toBe("failed");
  }));
});

describe("extracting a product", () => {
  it("partial metadata never chooses unrelated page images", () => {
    expect(extract("https://shop.example", { metadata: { title: "Page", ogImage: "/relative.jpg" }, images: ["https://cdn.example/logo.png"] }))
      .toEqual({ url: "https://shop.example", title: "Page", imageURLs: [], price: null });
    expect(extract("https://shop.example", {}).title).toBeNull();
  });

  it("falls back to alternate social metadata when ogImage is missing or invalid", () => {
    for (const key of ["og:image", "og:image:secure_url", "og:image:url", "twitter:image", "twitter:image:src"]) {
      expect(extract("https://shop.example", { metadata: { ogImage: "http://cdn.example/insecure.jpg", [key]: ["/relative.jpg", "https://cdn.example/product.jpg"] } }).imageURLs[0])
        .toBe("https://cdn.example/product.jpg");
    }
  });

  it("extracts HTML social images, decodes entities and preserves signed query strings", () => {
    const rawHtml = '<meta property="og:image" content="https://cdn.example/product.jpg?w=800&amp;signature=abc"><meta name="twitter:image" content="https://cdn.example/twitter.jpg">';
    expect(extract("https://shop.example", { rawHtml }).imageURLs[0]).toBe("https://cdn.example/product.jpg?w=800&signature=abc");
    expect(extract("https://shop.example", { rawHtml, metadata: { ogImage: "https://cdn.example/preferred.jpg" } }).imageURLs[0]).toBe("https://cdn.example/preferred.jpg");
    expect(extract("https://shop.example", { rawHtml: '<meta name="twitter:image" content="https://cdn.example/twitter.jpg">' }).imageURLs[0]).toBe("https://cdn.example/twitter.jpg");
  });

  it("Vinted gallery fallback selects the main listing photo and reports its source", () => {
    const rawHtml = '<img src="https://cdn.example/logo.png"><img data-testid="item-photo-1--img" src="https://images1.vinted.net/product.webp?s=signed"><img src="https://cdn.example/recommendation.jpg">';
    const { product, imageSource } = extractProduct("https://www.vinted.co.uk/items/10140550570-jacket?homepage_session_id=test", { metadata: { title: "Jacket" }, rawHtml });
    expect([product.imageURLs[0], imageSource]).toEqual(["https://images1.vinted.net/product.webp?s=signed", "Vinted listing gallery"]);
    for (const url of ["https://shop.example/items/123", "https://www.vinted.co.uk/member/123", "https://www.vinted.co.uk.evil.example/items/123"]) {
      expect(extract(url, { rawHtml }).imageURLs).toEqual([]);
    }
    expect(extract("https://www.vinted.co.uk/items/123", { rawHtml: '<img src="https://cdn.example/avatar.jpg">' }).imageURLs).toEqual([]);
  });

  it("all fallback image sources reject unsafe URLs", () => {
    for (const image of ["http://cdn.example/a.jpg", "https://127.0.0.1/a", "https://[::1]/a", "https://a.local/a", "https://user:pass@cdn.example/a", "data:image/png;base64,AA", "/relative.jpg"]) {
      expect(extract("https://www.vinted.co.uk/items/123", {
        metadata: { "twitter:image": image },
        rawHtml: `<meta property="og:image" content="${image}"><img data-testid="item-photo-1--img" src="${image}">`,
      }).imageURLs).toEqual([]);
    }
  });

  it("rejects local, encoded private, credential and non-web destinations", () => {
    for (const url of ["http://localhost/a", "http://a.localhost", "http://127.1", "http://2130706433", "http://10.0.0.1", "http://172.16.0.1", "http://192.168.0.1", "http://169.254.169.254", "http://[::1]", "http://[::ffff:127.0.0.1]", "http://[fc00::1]", "file:///tmp/a", "https://a:b@shop.example"]) {
      expect(() => publicURL(url)).toThrow();
    }
    expect(publicURL("https://shop.example/p?a=1#x").hash).toBe("#x");
  });

  it("returns all matching Vinted streamed photos in order, without thumbnails or other listings", () => {
    const primary = "https://images1.vinted.net/first.webp?s=one";
    const second = "https://images1.vinted.net/second.webp?s=two";
    const third = "https://images1.vinted.net/third.webp?s=three";
    const stream = "8e:" + JSON.stringify(["$", "gallery", null, { data: {
      item_id: "123", photos: [{ url: primary, thumbnails: [{ url: "https://cdn.example/thumb.jpg" }] }, { url: second }, { url: "https://127.0.0.1/private.jpg" }, { url: third }],
      recommendation: { item_id: "456", photos: [{ url: "https://cdn.example/unrelated.jpg" }] },
    } }]) + "\n";
    const script = (value: string) => `<script>self.__next_f.push(${JSON.stringify([1, value])})</script>`;
    const rawHtml = script(stream.slice(0, 100)) + script(stream.slice(100)) + '<img data-testid="item-photo-1--img" src="' + primary + '">';
    const product = extract("https://www.vinted.co.uk/items/123-jacket?size=M", { metadata: { ogImage: primary }, rawHtml });
    expect(product.imageURLs).toEqual([primary, second, third]);
  });

  it("reads only matching structured Product images and tolerates malformed scripts", () => {
    const products = { "@graph": [
      { "@type": "Product", name: "Unrelated", image: "https://cdn.example/unrelated.jpg" },
      { "@type": "Product", name: "Jacket", image: ["https://cdn.example/first.jpg", { "@type": "ImageObject", contentUrl: "https://cdn.example/second.jpg" }, "https://cdn.example/first.jpg", "http://cdn.example/unsafe.jpg"] },
    ] };
    const rawHtml = '<script type="application/ld+json">invalid</script><script type="application/ld+json">' + JSON.stringify(products) + "</script>";
    const product = extract("https://shop.example/jacket", { metadata: { title: "Jacket | Shop" }, rawHtml });
    expect(product.imageURLs).toEqual(["https://cdn.example/first.jpg", "https://cdn.example/second.jpg"]);
  });

  it("SSENSE uses all rendered SKU photos instead of the broken JSON-LD template", () => {
    const url = "https://www.ssense.com/en-us/men/product/julius/black-coated-big-shirt/19247841?utm_source=SSENSE";
    const photo = (index: number, transform = "f_auto,c_limit,w_1920", sku = "262420M192001") => `https://img.ssensemedia.com/images/${transform}/${sku}_${index}/julius-black-coated-big-shirt.jpg`;
    const rawHtml = `<script type="application/ld+json">${JSON.stringify({
      "@type": "Product", productID: "19247841", sku: "262420M192001", name: "Black Coated Big Shirt",
      url: url.split("?")[0], image: photo(1, "__IMAGE_PARAMS__"),
    })}</script>` + [photo(3), photo(1), photo(2), photo(4), photo(1, "w_640"), photo(1, "w_640", "OTHER")]
      .map((src) => `<img loading="lazy" src="${src}">`).join("");
    const { product, imageSource } = extractProduct(url, { metadata: { ogImage: photo(1, "w_640") }, rawHtml });
    expect(product.imageURLs).toEqual([1, 2, 3, 4].map((index) => photo(index)));
    expect([product.imageURLs[0], imageSource]).toEqual([photo(1), "product gallery"]);
    const fallback = extract(url, { metadata: { ogImage: photo(1, "w_640") }, rawHtml: rawHtml.replace(/<img[^>]*>/g, "") });
    expect(fallback.imageURLs).toEqual([photo(1, "w_640")]);
  });

  it("SSENSE gallery rejects unrelated SKUs, unsafe URLs and lookalike hosts", () => {
    const url = "https://www.ssense.com/en-us/men/product/julius/shirt/19247841";
    const primary = "https://img.ssensemedia.com/images/w_640/262420M192001_1/shirt.jpg";
    const rawHtml = `<script type="application/ld+json">${JSON.stringify({ "@type": "Product", productID: "999", sku: "OTHER" })}</script>
      <img src="https://img.ssensemedia.com/images/w_1920/OTHER_2/shirt.jpg">
      <img src="http://img.ssensemedia.com/images/w_1920/262420M192001_2/shirt.jpg">
      <img src="https://user:pass@img.ssensemedia.com/images/w_1920/262420M192001_2/shirt.jpg">
      <img src="https://img.ssensemedia.com.evil.example/images/w_1920/262420M192001_2/shirt.jpg">`;
    expect(extract(url, { metadata: { ogImage: primary }, rawHtml }).imageURLs).toEqual([primary]);
    expect(extract(url.replace("ssense.com", "ssense.com.evil.example"), {
      metadata: { ogImage: primary }, rawHtml: '<img src="https://img.ssensemedia.com/images/w_1920/262420M192001_2/shirt.jpg">',
    }).imageURLs).toEqual([primary]);
  });

  it("records the listing Price from Product JSON-LD offers, in minor units", () => {
    const ld = (value: unknown) => `<script type="application/ld+json">${JSON.stringify(value)}</script>`;
    const price = (rawHtml: string) => extract("https://shop.example/coat", { metadata: { title: "Coat" }, rawHtml }).price;
    expect(price(ld({ "@type": "Product", name: "Coat", offers: { "@type": "Offer", price: "249.50", priceCurrency: "GBP" } }))).toEqual({ amount: 24950, currency: "GBP" });
    expect(price(ld({ "@graph": [{ "@type": "Product", offers: [{ price: 1200, priceCurrency: "jpy" }] }] }))).toEqual({ amount: 1200, currency: "JPY" });
    expect(price(ld({ "@type": "Product", offers: { "@type": "AggregateOffer", lowPrice: "80", priceCurrency: "EUR" } }))).toEqual({ amount: 8000, currency: "EUR" });
  });

  it("records the listing Price from og and product price meta tags", () => {
    const meta = (prefix: string) => `<meta property="${prefix}:price:amount" content="1,045.00"><meta property="${prefix}:price:currency" content="USD">`;
    for (const prefix of ["og", "product"]) {
      expect(extract("https://shop.example/coat", { rawHtml: meta(prefix) }).price).toEqual({ amount: 104500, currency: "USD" });
    }
  });

  it("a page without a usable Price records none", () => {
    for (const rawHtml of ["", '<meta property="og:price:amount" content="12">', '<meta property="product:price:amount" content="free"><meta property="product:price:currency" content="GBP">',
      '<script type="application/ld+json">{"@type":"Product","offers":{"price":"10","priceCurrency":"pounds"}}</script>']) {
      expect(extract("https://shop.example/coat", { rawHtml }).price).toBeNull();
    }
  });
});
