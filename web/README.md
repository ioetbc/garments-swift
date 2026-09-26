This is a [Next.js](https://nextjs.org) project bootstrapped with [`create-next-app`](https://nextjs.org/docs/app/api-reference/cli/create-next-app).

## Getting Started

First, run the development server:

```bash
npm run dev
# or
yarn dev
# or
pnpm dev
# or
bun dev
```

Open [http://localhost:3000](http://localhost:3000) with your browser to see the result.

You can start editing the page by modifying `app/page.tsx`. The page auto-updates as you edit the file.

This project uses [`next/font`](https://nextjs.org/docs/app/building-your-application/optimizing/fonts) to automatically optimize and load [Geist](https://vercel.com/font), a new font family for Vercel.

## Learn More

To learn more about Next.js, take a look at the following resources:

- [Next.js Documentation](https://nextjs.org/docs) - learn about Next.js features and API.
- [Learn Next.js](https://nextjs.org/learn) - an interactive Next.js tutorial.

You can check out [the Next.js GitHub repository](https://github.com/vercel/next.js) - your feedback and contributions are welcome!

## Deploy on Vercel

The easiest way to deploy your Next.js app is to use the [Vercel Platform](https://vercel.com/new?utm_medium=default-template&filter=next.js&utm_source=create-next-app&utm_campaign=create-next-app-readme) from the creators of Next.js.

Check out our [Next.js deployment documentation](https://nextjs.org/docs/app/building-your-application/deploying) for more details.

## Product availability API

`POST /api/product-availability` classifies supplied HTML with the Vercel AI SDK's
experimental evaluation API and `typesafe-ai/jev`. It does not fetch URLs or run
page JavaScript; pass your hardcoded HTML (or rendered HTML from your client).

Copy `.env.example` to `.env.local` and set `AI_GATEWAY_API_KEY` to a key from
[Vercel AI Gateway](https://vercel.com/docs/ai-gateway/authentication-and-byok/authentication).
Set the same server-side variable in your deployment environment. No separate
TypeSafe key is needed. Never put the key in a `NEXT_PUBLIC_` variable or a client app.
Vercel OIDC authentication is also accepted when available.

```ts
const html = `<main><h1>Vintage jacket</h1><p>This item has sold</p></main>`;
const response = await fetch('/api/product-availability', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ html, url: 'https://example.com/products/jacket' }),
});
const result = await response.json();
if (!response.ok) throw new Error(result.error);
// { status: 'sold', available: false, confidence: 0.98, model: 'typesafe-ai/jev' }
// Example only: confidence is model-reported and may be null.
```

`html` is required; `url` is optional context. Classification statuses are `unknown`,
`available`, and `sold`. `sold` covers every confirmed unavailable state, including
out of stock, removed, and ended listings. `available` requires positive purchase
availability evidence. Missing, conflicting, or blocked evidence returns `unknown`,
with `available: null`; otherwise `available` is a boolean. The server also defaults
to `unknown` unless Jev reports at least 75% probability for its selected
`available` or `sold` answer. Missing or invalid probabilities return `unknown`.
The model focuses on the main product or selected variant rather than recommended items.

HTML extraction retains page text, product metadata, button state and JSON-LD,
while removing executable scripts and styles. Requests are limited to 1 MB and
extracted content to 24,000 characters; oversized content is rejected rather than
truncated, so availability evidence is not silently dropped. Submit the product
section and its structured data for larger pages.

Errors: `400` invalid input, `413` oversized input, `415` wrong content type,
`422` empty/unusable extracted content,
`503` missing server credentials, `502` model failure/timeout. Errors never imply
that a product is available. Classification is probabilistic; confidence is the
model's reported probability, not a guarantee. The route currently follows the
app's unauthenticated API pattern; add app authentication and rate limiting before
exposing paid inference publicly.

Run local checks with `bun test`, `bunx tsc --noEmit`, and `bun run lint`.

## URL to Markdown (Firecrawl)

No Firecrawl key is required to try scraping. For higher limits, optionally set
`FIRECRAWL_API_KEY` in `web/.env.local` (and your deployment environment), then
restart the web server. The key stays on the server; the Swift app only needs its
existing `GARMS_API_BASE_URL` configuration. Only Markdown is requested.

In the iOS product details form, tap **Listing availability → Check availability** to scrape
the product’s `product_url` from `CanvasFixtures.swift`. Fixtures use a mix of Vinted, eBay, and SSENSE listings, also shown in each
product’s URL row. The drawer shows the Jev classification. **View Markdown** opens the retrieved content with a share action.
Loading, validation, service errors, and source HTTP errors are displayed. Leaving
the view cancels the client task. The server passes Markdown to Jev, with the source URL and HTTP status as context. Known hidden accessibility elements are excluded during scraping before Markdown conversion. Set `AI_GATEWAY_API_KEY` as described above.

`POST /api/scrape` accepts `{ "url": "https://example.com/product" }` and returns:

```json
{ "url": "https://example.com/product", "markdown": "# Product\n…", "title": "Product", "statusCode": 200, "classification": { "status": "sold", "error": null, "model": "typesafe-ai/jev" }, "updatedAt": "2026-09-25T12:00:00.000Z" }
```

`title` and source `statusCode` may be null. A source 404/410 may still have useful
Markdown, so its status is preserved separately from this API's status. No usable
Markdown returns 422. Invalid input returns 400/413/415; rejected credentials, access, or
insufficient credits return 503, throttling 429, upstream failures 502, and timeout
504. The server uses the installed `firecrawl` SDK to call [Firecrawl v2 scrape](https://docs.firecrawl.dev/api-reference/endpoint/scrape)
with Markdown output, `onlyMainContent: false` to retain product details, and `maxAge: 0` for fresh product data.
Known hidden elements are excluded before Markdown conversion. No extra render wait
is added: on the investigated Vinted listing, waiting loaded unrelated recommendations
and pushed the page beyond the classification limit. Sparse content and isolated UI
announcements are not sufficient availability evidence.
Automatic retries and long-running auto-resume are disabled. The SDK bounds
requests to 50 seconds; cancelling the iOS task stops waiting locally, but an
already submitted Firecrawl scrape may continue on the server.
Like the existing API, this endpoint requires app authentication/rate limiting
before exposing it publicly as a paid service.

The combined scrape route allows 90 seconds, with a 50-second scrape budget and
20-second classification budget; inference retries are disabled. The iOS request
allows 95 seconds. Classification failures return HTTP 200 with the fetched
Markdown and `classification.status: "unknown"` plus an explanatory `error`.
The drawer shows **Couldn’t check** with the reason for provider demand, rate limits,
authentication failures, timeouts, or connection errors. Raw provider details stay
in server logs; failures are not treated as sold.
Access failures (except 404/410) and Markdown over 24,000 characters skip inference.
Unreadable results become unknown, and a source 404/410 can never become active.
The drawer displays `available` as **Available**, separately from personal ownership
status. The canvas checks each product independently on load and fades unavailable
products; manual drawer checks also update the canvas. Successful results are
cached on the server as described below.

## Server availability cache

`/api/scrape` saves successful availability results as JSON files in
`web/.cache/scrape/` (relative to the web server working directory). Each URL has
a hashed filename and stores the full response, including an ISO `updatedAt`.
Checks less than 24 hours old return the saved response without calling Firecrawl
or Jev. At 24 hours or older, the next check refreshes both services and replaces
the file. URL fragments are ignored; query parameters remain part of the key.
Unknown classifications and failed requests are not cached, so they can be retried.

Set `SCRAPE_CACHE_DIR` to override the directory, ideally to an absolute writable
persistent path on the server. This cache survives app/server restarts when the
filesystem persists; it is local to each server and is not shared across instances.
Ephemeral deployments need a persistent volume for retention. Writes are atomic;
cache read/write failures are logged and do not prevent live checks. Delete the
cache files to force fresh checks. No iOS changes are required.
