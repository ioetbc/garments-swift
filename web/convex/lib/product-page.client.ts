import { Firecrawl, type Document, SdkError } from "firecrawl";
import { Context, Effect, Layer } from "effect";
import { isIP } from "node:net";
import { load } from "cheerio";
import type { ImportedProduct } from "../validators";
import { ImportFailed, InvalidInput } from "./errors";

/** Fetches a page as markdown, raw HTML and metadata. */
export type Scrape = (url: string) => Promise<Document>;

const firecrawl: Scrape = (url) =>
  new Firecrawl({ apiKey: process.env.FIRECRAWL_API_KEY, timeoutMs: 50_000, maxRetries: 1 })
    .scrape(url, { formats: ["markdown", "rawHtml"], onlyMainContent: true, maxAge: 0, timeout: 45_000, autoResume: false });

/** A product page scraped through Firecrawl. One scrape per import. */
export class ProductPageReader extends Context.Service<ProductPageReader, {
  /** A public product page's title, Price and images. */
  read(url: string): Effect.Effect<ImportedProduct, InvalidInput | ImportFailed>;
}>()("garms/ProductPageReader") {
  /** Reads pages fetched by `scrape`. */
  static readonly make = (scrape: Scrape) => ProductPageReader.of({
    read: Effect.fn("ProductPageReader.read")(function* (submitted: string) {
      const url = submitted.trim();
      if (!isPublic(url)) return yield* new InvalidInput({ message: "Provide a public HTTP(S) URL without credentials." });
      // One line per step, so a bad import can be traced in the deployment's logs.
      const log = (step: string, details: object) => Effect.sync(() => console.info(`Product import: ${step}`, JSON.stringify(details)));
      const started = Date.now();
      const page = yield* Effect.tryPromise({
        try: () => scrape(url),
        catch: (cause) => new ImportFailed({ reason: cause instanceof SdkError && cause.status === 429 ? "busy" : "failed", cause }),
      }).pipe(Effect.tapError((error) => Effect.sync(() => console.error("Product import: Firecrawl failed", error.cause))));
      const status = page.metadata?.statusCode;
      yield* log("scraped", { host: new URL(url).hostname, status, markdown: page.markdown?.length ?? 0, ms: Date.now() - started });
      if ((status ?? 200) >= 400) return yield* new ImportFailed({ reason: "unreachable", cause: status });
      const { product, imageSource } = extractProduct(url, page);
      yield* log("extracted", { title: product.title !== null, imageSource: imageSource ?? null, gallery: product.imageURLs.length });
      return product;
    }),
  });

  static readonly layer = Layer.sync(ProductPageReader, () => ProductPageReader.make(firecrawl));
}

/** The URL, if it is a public HTTP(S) address without credentials; throws otherwise. */
export function publicURL(value: string): URL {
  if (value.length > 4096) throw new Error("URL too long");
  const url = new URL(value);
  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "").replace(/\.$/, "");
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password ||
      !host.includes(".") && !isIP(host) || host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) throw new Error("Invalid destination");
  if (isIP(host) === 4) {
    const [a, b] = host.split(".").map(Number);
    if (a === 0 || a === 10 || a === 127 || a >= 224 || a === 169 && b === 254 || a === 172 && b >= 16 && b <= 31 || a === 192 && b === 168 || a === 100 && b >= 64 && b <= 127 || a === 198 && [18, 19].includes(b)) throw new Error("Private destination");
  }
  // Permit only global unicast IPv6; disallow mapped IPv4 and local ranges.
  if (isIP(host) === 6 && !/^[23][0-9a-f]{3}:/.test(host)) throw new Error("Private destination");
  return url;
}

function selectImportImage(url: string, document: Document): { url: string; source: string } | null {
  const candidate = (value: unknown, source: string): { url: string; source: string } | null => {
    // Duplicate metadata tags may be returned as arrays by the scrape provider.
    for (const entry of Array.isArray(value) ? value : [value]) {
      if (typeof entry !== "string" || !entry.trim()) continue;
      try {
        const image = publicURL(entry.trim());
        if (image.protocol === "https:") return { url: image.href, source };
      } catch { /* Try the next explicit product image, preserving URL validation. */ }
    }
    return null;
  };
  for (const key of ["ogImage", "og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"]) {
    const image = candidate(document.metadata?.[key], `metadata ${key}`);
    if (image) return image;
  }
  if (!document.rawHtml) return null;
  const $ = load(document.rawHtml);
  for (const key of ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"]) {
    const values = $(`meta[property="${key}"], meta[name="${key}"]`).map((_, element) => $(element).attr("content")).get();
    const image = candidate(values, `HTML ${key}`);
    if (image) return image;
  }
  // Vinted's listing gallery is distinct from seller avatars and recommended items.
  const page = new URL(url);
  if (["vinted.co.uk", "www.vinted.co.uk"].includes(page.hostname) && /^\/items\/\d+/.test(page.pathname)) {
    const image = candidate($('img[data-testid="item-photo-1--img"]').attr("src"), "Vinted listing gallery");
    if (image) return image;
  }
  return null;
}

// Read data, never execute page scripts. Match embedded galleries to this listing.
function productGallery(url: string, document: Document, primary: string | undefined): string[] {
  const images = new Set<string>();
  const add = (value: unknown) => {
    if (typeof value !== "string") return;
    try {
      const image = publicURL(value.trim());
      // SSENSE exposes this unexpanded template in Product JSON-LD; it returns 404.
      if (image.hostname === "img.ssensemedia.com" && image.pathname.includes("__IMAGE_PARAMS__")) return;
      if (image.protocol === "https:") images.add(image.href);
    } catch { /* Ignore unusable gallery entries. */ }
  };
  add(primary);
  if (!document.rawHtml) return [...images];
  const $ = load(document.rawHtml);
  const page = new URL(url);
  const listingID = ["vinted.co.uk", "www.vinted.co.uk"].includes(page.hostname)
    ? page.pathname.match(/^\/items\/(\d+)(?:-|$)/)?.[1] : undefined;
  const walk = (value: unknown, visit: (node: Record<string, unknown>) => void, depth = 0) => {
    if (depth > 60 || value === null || typeof value !== "object") return;
    if (Array.isArray(value)) { for (const entry of value) walk(entry, visit, depth + 1); return; }
    const node = value as Record<string, unknown>;
    visit(node);
    for (const entry of Object.values(node)) walk(entry, visit, depth + 1);
  };
  const ssenseID = ["ssense.com", "www.ssense.com"].includes(page.hostname)
    ? page.pathname.match(/\/product\/[^/]+\/[^/]+\/(\d+)\/?$/)?.[1] : undefined;
  if (ssenseID) {
    let sku: string | undefined;
    $('script[type="application/ld+json"]').each((_, element) => {
      try {
        walk(JSON.parse($(element).text()), node => {
          const types = Array.isArray(node["@type"]) ? node["@type"] : [node["@type"]];
          if (types.includes("Product") && String(node.productID) === ssenseID && typeof node.sku === "string") sku = node.sku;
        });
      } catch { /* A missing SKU can still be identified by the primary image. */ }
    });
    const photoIdentity = (value: string | undefined) => {
      if (!value) return null;
      try {
        const image = publicURL(value);
        if (image.protocol !== "https:" || image.hostname !== "img.ssensemedia.com") return null;
        const match = image.pathname.match(/^\/images\/([^/]+)\/([^/]+)_(\d+)\/[^/]+$/);
        if (!match || match[1].includes("__IMAGE_PARAMS__")) return null;
        return { url: image.href, sku: match[2], index: Number(match[3]) };
      } catch { return null; }
    };
    sku ??= photoIdentity(primary)?.sku;
    // Use only URLs present on the page for this SKU, not guessed image numbers
    // or recommended products. The rendered URLs include the real CDN transforms.
    const photos = new Map<number, string>();
    if (sku) {
      $('img[src]').each((_, element) => {
        const photo = photoIdentity($(element).attr("src"));
        if (photo && photo.sku === sku && !photos.has(photo.index)) photos.set(photo.index, photo.url);
      });
    }
    if (photos.size) return [...photos.entries()].sort(([a], [b]) => a - b).map(([, address]) => address);
  }
  if (listingID) {
    // React's streamed data may span multiple script chunks. Decode only JSON strings.
    const chunks: string[] = [];
    $('script').each((_, element) => {
      const script = $(element).text().trim();
      const match = script.match(/^self\.__next_f\.push\((\[[\s\S]*\])\);?$/);
      if (!match) return;
      try {
        const chunk = JSON.parse(match[1]);
        if (chunk[0] === 1 && typeof chunk[1] === "string") chunks.push(chunk[1]);
      } catch { /* Other scripts are not gallery data. */ }
    });
    for (const line of chunks.join("").split("\n")) {
      const payload = line.slice(line.indexOf(":") + 1);
      if (!payload.startsWith("[") && !payload.startsWith("{")) continue;
      try {
        walk(JSON.parse(payload), node => {
          if (String(node.item_id ?? node.id) !== listingID || !Array.isArray(node.photos)) return;
          for (const photo of node.photos) {
            if (photo && typeof photo === "object") add(photo.url);
          }
        });
      } catch { /* Ignore non-JSON stream records. */ }
    }
    $('img[data-testid]').toArray()
      .map(element => ({ element, index: $(element).attr("data-testid")?.match(/^item-photo-(\d+)--img$/)?.[1] }))
      .filter(entry => entry.index !== undefined)
      .sort((a, b) => Number(a.index) - Number(b.index))
      .forEach(({ element }) => add($(element).attr("src")));
  }
  const title = document.metadata?.ogTitle ?? document.metadata?.title;
  $('script[type="application/ld+json"]').each((_, element) => {
    try {
      walk(JSON.parse($(element).text()), node => {
        const types = Array.isArray(node["@type"]) ? node["@type"] : [node["@type"]];
        if (!types.includes("Product")) return;
        const matchesURL = typeof node.url === "string" && new URL(node.url, url).origin === page.origin && new URL(node.url, url).pathname === page.pathname;
        const matchesTitle = typeof node.name === "string" && typeof title === "string" && node.name.trim() === title.split(" | ")[0].trim();
        if (!matchesURL && !matchesTitle) return;
        for (const image of Array.isArray(node.image) ? node.image : [node.image]) {
          add(typeof image === "object" && image ? image.contentUrl ?? image.url : image);
        }
      });
    } catch { /* Malformed structured data must not fail an otherwise usable import. */ }
  });
  return [...images];
}

/** Converts a listing's major-unit amount, as pages write it, to integer minor units. */
function toPrice(amount: unknown, currency: unknown): { amount: number; currency: string } | null {
  if (typeof currency !== "string" || !/^[a-z]{3}$/i.test(currency.trim())) return null;
  const code = currency.trim().toUpperCase();
  const major = typeof amount === "number" ? amount : typeof amount === "string" ? Number(amount.replace(/[^\d.]/g, "")) : NaN;
  if (!Number.isFinite(major) || major < 0 || typeof amount === "string" && !/\d/.test(amount)) return null;
  let digits: number;
  try { digits = new Intl.NumberFormat("en", { style: "currency", currency: code }).resolvedOptions().maximumFractionDigits ?? 2; }
  catch { return null; }
  return { amount: Math.round(major * 10 ** digits), currency: code };
}

// Structured data first, then price meta tags; the page is the only source of a Price.
function listingPrice(document: Document): { amount: number; currency: string } | null {
  if (!document.rawHtml) return null;
  const $ = load(document.rawHtml);
  let price: { amount: number; currency: string } | null = null;
  $('script[type="application/ld+json"]').each((_, element) => {
    if (price) return;
    try {
      const visit = (value: unknown, depth = 0): void => {
        if (price || depth > 60 || value === null || typeof value !== "object") return;
        if (Array.isArray(value)) { for (const entry of value) visit(entry, depth + 1); return; }
        const node = value as Record<string, unknown>;
        const types = Array.isArray(node["@type"]) ? node["@type"] : [node["@type"]];
        if (types.includes("Product")) {
          for (const offer of Array.isArray(node.offers) ? node.offers : [node.offers]) {
            if (!offer || typeof offer !== "object") continue;
            const o = offer as Record<string, unknown>;
            price ??= toPrice(o.price ?? o.lowPrice, o.priceCurrency);
          }
        }
        for (const entry of Object.values(node)) visit(entry, depth + 1);
      };
      visit(JSON.parse($(element).text()));
    } catch { /* Malformed structured data must not fail an otherwise usable import. */ }
  });
  const meta = (key: string) => $(`meta[property="${key}"], meta[name="${key}"]`).attr("content");
  for (const prefix of ["og", "product"]) price ??= toPrice(meta(`${prefix}:price:amount`), meta(`${prefix}:price:currency`));
  return price;
}

const isPublic = (url: string) => {
  try { publicURL(url); return true; } catch { return false; }
};

/** The product, and where its main image came from, read off a scraped page. */
export function extractProduct(url: string, document: Document): { product: ImportedProduct; imageSource: string | undefined } {
  const metadata = document.metadata;
  const title = [metadata?.ogTitle, metadata?.title].find(v => typeof v === "string" && v.trim());
  const image = selectImportImage(url, document);
  const imageURLs = productGallery(url, document, image?.url);
  const price = listingPrice(document);
  return {
    product: { url, title: title?.trim().slice(0, 500) ?? null, imageURLs, price },
    imageSource: imageURLs[0] === image?.url ? image?.source : (imageURLs.length ? "product gallery" : undefined),
  };
}
