import { Firecrawl, type Document, SdkError } from "firecrawl";
import { isIP } from "node:net";

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

export function normalizeImport(url: string, document: Document) {
  const metadata = document.metadata;
  const title = [metadata?.ogTitle, metadata?.title].find(v => typeof v === "string" && v.trim());
  let imageURL: string | null = null;
  if (typeof metadata?.ogImage === "string") {
    try {
      const image = publicURL(metadata.ogImage.trim());
      if (image.protocol === "https:") imageURL = image.href;
    } catch { /* Missing or unsuitable artwork is a valid partial result. */ }
  }
  return { url, title: title?.trim().slice(0, 500) ?? null, imageURL };
}

async function scrape(url: string): Promise<Document> {
  return new Firecrawl({ apiKey: process.env.FIRECRAWL_API_KEY, timeoutMs: 50_000, maxRetries: 1 })
    .scrape(url, { formats: ["markdown"], onlyMainContent: true, maxAge: 0, timeout: 45_000, autoResume: false });
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
    try {
      if (request.signal.aborted) return json({ error: "Import cancelled." }, 499);
      const result = await fetchPage(submitted);
      if (request.signal.aborted) return json({ error: "Import cancelled." }, 499);
      if ((result.metadata?.statusCode ?? 200) >= 400) return json({ error: "The product page could not be accessed." }, 422);
      return json(normalizeImport(submitted, result));
    } catch (error) {
      const status = error instanceof SdkError ? error.status : undefined;
      return json({ error: status === 429 ? "Import service is busy. Try again shortly." : "The page could not be imported. Please retry." }, status === 429 ? 429 : 502);
    }
  };
}
