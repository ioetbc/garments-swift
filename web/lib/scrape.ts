import { Firecrawl, SdkError, type Document } from "firecrawl";
import { availabilityErrorMessage, classifyProduct, HIDDEN_CONTENT_SELECTORS, MAX_CONTENT_LENGTH, MODEL } from "./product-availability";
import { createScrapeCache } from "./scrape-cache";

export type ScrapeResult = {
  url: string;
  markdown: string;
  title: string | null;
  statusCode: number | null;
  classification: Classification;
  updatedAt: string;
};

type Classification = {
  status: "unknown" | "available" | "sold";
  error: string | null;
  model: string;
};

async function classifyContent(
  content: string, url: string, statusCode: number | null, classify: typeof classifyProduct,
): Promise<Classification> {
  const unknown = (error: string): Classification => ({ status: "unknown", error, model: MODEL });
  if (statusCode != null && statusCode >= 400 && ![404, 410].includes(statusCode)) {
    return unknown("The source page could not be accessed. Try checking again later.");
  }
  if (!content.trim()) return unknown("The page does not provide usable product availability evidence.");
  if (content.length > MAX_CONTENT_LENGTH) {
    return unknown("The page is too large to classify. Its Markdown is still available.");
  }
  try {
    const answer = await classify(content, url, statusCode);
    if (answer.choice === "unknown" || (statusCode != null && statusCode >= 400 && answer.choice === "available")) {
      return unknown("The page does not provide clear product availability information.");
    }
    return { status: answer.choice, error: null, model: MODEL };
  } catch (error) {
    let message = error instanceof Error ? error.message : "Unknown provider error";
    for (const secret of [process.env.AI_GATEWAY_API_KEY, process.env.VERCEL_OIDC_TOKEN]) {
      if (secret) message = message.replaceAll(secret, "[redacted]");
    }
    console.error("jev error", {
      name: error instanceof Error ? error.name : "UnknownError",
      message,
      statusCode: error && typeof error === "object" && "statusCode" in error ? error.statusCode : undefined,
    });
    return unknown(availabilityErrorMessage(error));
  }
}

async function scrapePage(url: string, apiKey?: string): Promise<Document> {
  const client = new Firecrawl({
    apiKey, timeoutMs: 50_000,
    // SDK 4.41 counts total attempts here; 1 means no automatic retries.
    maxRetries: 1,
  });
  return client.scrape(url, {
    formats: ["markdown"],
    // Main-content filtering can omit the product details and purchase state.
    onlyMainContent: false,
    excludeTags: HIDDEN_CONTENT_SELECTORS,
    maxAge: 0, timeout: 45_000, autoResume: false,
  });
}

function json(body: unknown, status = 200) {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}

export function createScrapeHandler(
  scrape: typeof scrapePage = scrapePage,
  classify: typeof classifyProduct = classifyProduct,
  cache: ReturnType<typeof createScrapeCache> | null = createScrapeCache(),
) {
  return async function POST(request: Request) {
    if (request.headers.get("content-type")?.split(";")[0].trim() !== "application/json") {
      return json({ error: "Content-Type must be application/json." }, 415);
    }
    let url: URL;
    try {
      const reader = request.body?.getReader();
      if (!reader) return json({ error: "A JSON body is required." }, 400);
      const chunks: Uint8Array[] = [];
      let size = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > 8192) {
          await reader.cancel();
          return json({ error: "Request body exceeds 8 KB." }, 413);
        }
        chunks.push(value);
      }
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      if (typeof body?.url !== "string" || body.url.length > 4096) throw new Error();
      url = new URL(body.url.trim());
      if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) throw new Error();
      url.hash = "";
    } catch {
      return json({ error: "Provide a valid HTTP(S) URL without credentials in a JSON url field." }, 400);
    }

    const apiKey = process.env.FIRECRAWL_API_KEY;

    try {
      if (request.signal.aborted) return json({ error: "Scrape cancelled." }, 499);
      const cached = await cache?.get(url.href);
      console.log("using cache?", cached?.classification.status);
      if (cached) {
        console.log("markdown", cached.markdown);
        console.log("cached classification", cached.classification);
        return json(cached);
      }
      const result = await scrape(url.href, apiKey);
      const markdown = result?.markdown;
      console.log("markdown", markdown);
      console.log("result", result);
      if (typeof markdown !== "string" || !markdown.trim()) {
        return json({ error: "This page returned no Markdown content." }, 422);
      }
      const metadata = result?.metadata;
      const statusCode = typeof metadata?.statusCode === "number" ? metadata.statusCode : null;
      if (request.signal.aborted) return json({ error: "Scrape cancelled." }, 499);
      const classification = await classifyContent(markdown, url.href, statusCode, classify);
      console.log("classification", classification);

      const response: ScrapeResult = {
        url: url.href,
        markdown,
        title: typeof metadata?.title === "string" ? metadata.title : null,
        // Preserve target HTTP status so removed/error pages aren't treated as available.
        statusCode,
        classification,
        updatedAt: new Date().toISOString(),
      };
      await cache?.set(response);
      return json(response);
    } catch (error) {
      if (request.signal.aborted) return json({ error: "Scrape cancelled." }, 499);
      if (error instanceof SdkError) {
        if (error.status === 429) return json({ error: "Scraping is busy. Please try again shortly." }, 429);
        if ([401, 402, 403].includes(error.status ?? 0)) {
          return json({ error: "Firecrawl credentials, access, or credits need attention on the server." }, 503);
        }
        if ([408, 504].includes(error.status ?? 0) || error.code === "SCRAPE_TIMEOUT" || /timeout|timed out/i.test(error.message)) {
          return json({ error: "The page took too long to scrape. Please retry." }, 504);
        }
      }
      return json({ error: "Firecrawl could not retrieve this page. Try another URL or retry." }, 502);
    }
  };
}
