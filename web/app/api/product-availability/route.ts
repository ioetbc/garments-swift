import { availabilityErrorMessage, classifyProduct, extractPageContent, MAX_CONTENT_LENGTH, MODEL } from "@/lib/product-availability";

export const runtime = "nodejs";
export const maxDuration = 30;
const MAX_BODY_BYTES = 1_000_000;

function json(body: unknown, status = 200) {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}

export async function POST(request: Request) {
  if (!request.headers.get("content-type")?.includes("application/json")) {
    return json({ error: "Content-Type must be application/json." }, 415);
  }

  let body: unknown;
  try {
    const reader = request.body?.getReader();
    if (!reader) return json({ error: "A JSON body is required." }, 400);
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BODY_BYTES) {
        await reader.cancel();
        return json({ error: "Request body exceeds 1 MB." }, 413);
      }
      chunks.push(value);
    }
    body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    return json({ error: "Invalid JSON body." }, 400);
  }

  if (!body || typeof body !== "object" || !("html" in body) ||
      typeof body.html !== "string" || !body.html.trim()) {
    return json({ error: "html must be a non-empty string." }, 400);
  }
  let url: string | undefined;
  if ("url" in body) {
    try {
      if (typeof body.url !== "string") throw new Error();
      const parsed = new URL(body.url);
      if (!["https:", "http:"].includes(parsed.protocol) || parsed.username || parsed.password) throw new Error();
      url = parsed.href;
    } catch {
      return json({ error: "url must be an HTTP(S) URL without credentials." }, 400);
    }
  }

  const content = extractPageContent(body.html);
  if (!content) return json({ error: "HTML contains no usable page content." }, 422);
  if (content.length > MAX_CONTENT_LENGTH) {
    return json({ error: `Extracted content exceeds ${MAX_CONTENT_LENGTH} characters. Submit the product section and its structured data.` }, 413);
  }
  if (!process.env.AI_GATEWAY_API_KEY && !process.env.VERCEL_OIDC_TOKEN) {
    return json({ error: "Configure AI_GATEWAY_API_KEY on the server." }, 503);
  }

  try {
    const answer = await classifyProduct(content, url);
    return json({
      status: answer.choice,
      available: answer.choice === "unknown" ? null : answer.choice === "available",
      confidence: answer.probabilities?.[answer.choice] ?? null,
      model: MODEL,
    });
  } catch (error) {
    return json({ error: availabilityErrorMessage(error) }, 502);
  }
}
