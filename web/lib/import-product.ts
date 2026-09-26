import { Firecrawl, type Document, SdkError } from "firecrawl";
import { isIP } from "node:net";
import { randomUUID } from "node:crypto";
import { load } from "cheerio";

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

function extractImport(url: string, document: Document) {
  const metadata = document.metadata;
  const title = [metadata?.ogTitle, metadata?.title].find(v => typeof v === "string" && v.trim());
  const image = selectImportImage(url, document);
  const imageURLs = productGallery(url, document, image?.url);
  return { product: { url, title: title?.trim().slice(0, 500) ?? null, imageURL: imageURLs[0] ?? null, imageURLs }, imageSource: imageURLs[0] === image?.url ? image?.source : (imageURLs.length ? "product gallery" : undefined) };
}

export function normalizeImport(url: string, document: Document) {
  return extractImport(url, document).product;
}

async function scrape(url: string): Promise<Document> {
  return new Firecrawl({ apiKey: process.env.FIRECRAWL_API_KEY, timeoutMs: 50_000, maxRetries: 1 })
    .scrape(url, { formats: ["markdown", "rawHtml"], onlyMainContent: true, maxAge: 0, timeout: 45_000, autoResume: false });
}
const json = (body: unknown, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
export function createImportHandler(fetchPage: typeof scrape = scrape) {
  return async (request: Request) => {
    if (request.headers.get("content-type")?.split(";")[0].trim() !== "application/json") return json({ error: "Content-Type must be application/json." }, 415);
    let submitted: string;
    try {
      const reader = request.body?.getReader();
      if (!reader) throw new Error();
      const chunks: Uint8Array[] = [];
      let size = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > 8192) { await reader.cancel(); return json({ error: "Request body exceeds 8 KB." }, 413); }
        chunks.push(value);
      }
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      if (typeof body?.url !== "string") throw new Error();
      submitted = body.url.trim();
      publicURL(submitted);
    } catch { return json({ error: "Provide a public HTTP(S) URL without credentials." }, 400); }
    const requestID = randomUUID();
    const started = Date.now();
    const diagnostics: string[] = [];
    const log = (message: string, warning = false) => {
      const line = `[${new Date().toISOString()}] ${warning ? "WARNING" : "INFO"} ${requestID} ${message}`;
      diagnostics.push(line);
      if (warning) console.warn(line); else console.info(line);
    };
    try {
      if (request.signal.aborted) return json({ error: "Import cancelled.", diagnostics }, 499);
      log(`Firecrawl scrape started for ${new URL(submitted).hostname}; requesting markdown, raw HTML and metadata.`);
      const result = await fetchPage(submitted);
      log(`Firecrawl completed in ${Date.now() - started}ms. Page HTTP status: ${result.metadata?.statusCode ?? "not supplied"}. Markdown: ${result.markdown?.length ?? 0} characters.`);
      if (!result.markdown?.trim()) log("Firecrawl returned no markdown; trying metadata extraction anyway.", true);
      if (request.signal.aborted) return json({ error: "Import cancelled.", diagnostics }, 499);
      if ((result.metadata?.statusCode ?? 200) >= 400) {
        log(`Product page returned HTTP ${result.metadata?.statusCode}.`, true);
        return json({ error: "The product page could not be accessed.", diagnostics }, 422);
      }
      const { product, imageSource } = extractImport(submitted, result);
      log(`Metadata extracted. Title: ${product.title ? "present" : "missing"}. HTTPS product image: ${imageSource ?? "missing or rejected"}. Gallery: ${product.imageURLs.length} images.`);
      if (!product.imageURL) log("No usable product image in social metadata or supported listing gallery. Candidates must be absolute public HTTPS URLs without credentials.", true);
      return json({ ...product, diagnostics });
    } catch (error) {
      const status = error instanceof SdkError ? error.status : undefined;
      // Return useful provider details without exposing API keys, page bodies or URL queries.
      let detail = error instanceof Error ? `${error.name}: ${error.message}` : "Unknown provider error";
      const key = process.env.FIRECRAWL_API_KEY;
      if (key) detail = detail.split(key).join("[redacted]");
      detail = detail.replace(/https?:\/\/[^\s"'<>]+/g, "[URL redacted]")
        .replace(/(?:Bearer\s+)[^\s,;]+/gi, "Bearer [redacted]")
        .replace(/fc-[a-zA-Z0-9_-]+/g, "[key redacted]").slice(0, 4000);
      log(`Firecrawl failed after ${Date.now() - started}ms${status ? `; HTTP ${status}` : ""}. ${detail}`, true);
      return json({ error: status === 429 ? "Import service is busy. Try again shortly." : "The page could not be imported. Please retry.", diagnostics }, status === 429 ? 429 : 502);
    }
  };
}
